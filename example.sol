// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ERC20} from "./ERC20.sol";
import {ERC20Reserveless} from "./ERC20Reserveless.sol";
import {TokenCenterCore} from "./TokenCenterCore.sol";
import {ITokenCenter} from "./interfaces/ITokenCenter.sol";
import {Impl} from "@project/contract-center/contracts/libraries/Impl.sol";
import {_calculateSellOutput, _calculateSellInput, _calculateBuyOutput, _calculateBuyInput} from "./libraries/TokenMath.sol";

contract TokenCenter is
    ITokenCenter,
    TokenCenterCore,
    OwnableUpgradeable,
    PausableUpgradeable,
    Impl
{
    /* ========== STRUCTS ========== */

    struct Token {
        uint256 initialMint;
        uint256 minTotalSupply;
        uint256 maxTotalSupply;
        address creator;
        uint8 crr;
        string identity;
        string symbol;
        string name;
    }

    /* ========== EVENTS ========== */

    event TokenDeployed(address tokenAddress, Token meta);
    event TokenReservelessDeployed(address tokenAddress);
    event TokenUpgraded(
        address indexed oldContract,
        address indexed newContract
    );
    event TokenReservelessUpgraded(
        address indexed oldContract,
        address indexed newContract
    );

    /* ========== ERRORS ========== */

    error InvalidMinReserve();
    error InvalidComission(uint256 expectedCommission);
    error TokenSymbolExist();
    error InvalidAddress();
    error DeployTokenError();

    /* ==========  TOKEN CENTER ========== */

    function initialize() public virtual initializer {
        // this function needs to be exposed for an upgrade to pass
    }

    function convert(
        address payable tokenIn,
        address payable tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused {
        ERC20(tokenIn).permit(
            msg.sender,
            address(this),
            amountIn,
            deadline,
            v,
            r,
            s
        );
        convert(tokenIn, tokenOut, amountIn, amountOutMin, recipient);
    }

    function convert(
        address payable tokenIn,
        address payable tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient
    ) public whenNotPaused {
        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        uint256 ethAmount = ERC20(tokenIn).calculateSellOutput(amountIn);

        // amountOutMin is 0 because we use slippage in buy function
        ERC20(tokenIn).sell(amountIn, 0, address(this));

        ERC20(tokenOut).buy{value: ethAmount}(amountOutMin, recipient);
    }

    function createToken(
        Token memory meta
    ) public payable virtual whenNotPaused {
        uint256 commission = getCommissionSymbol(meta.symbol);

        if (msg.value < commission) {
            revert InvalidComission(commission);
        }
        uint256 reserve = msg.value - commission;

        payable(address(0)).transfer(commission);
        _createToken(meta, reserve);
    }

    function _createToken(
        Token memory meta,
        uint256 reserve
    ) internal returns (address) {
        if (tokens(meta.symbol) != address(0)) revert TokenSymbolExist();

        // initialize the ERC20
        bytes memory initialisationArgs = abi.encodeWithSelector(
            ERC20.initialize.selector,
            meta.name,
            meta.symbol,
            meta.creator,
            meta.crr,
            meta.initialMint,
            meta.minTotalSupply,
            meta.maxTotalSupply,
            meta.identity
        );

        bytes32 salt = keccak256(abi.encodePacked(meta.symbol));

        address beaconAddress = address(this);
        address predictedAddress = predict(
            beaconAddress,
            salt,
            initialisationArgs
        );

        emit TokenDeployed(predictedAddress, meta);

        address deployedAddress = address(
            new BeaconProxy{value: reserve, salt: salt}(
                beaconAddress,
                initialisationArgs
            )
        );

        if (deployedAddress != predictedAddress) revert DeployTokenError();

        _getTokenCenterStorage()._tokens[meta.symbol] = deployedAddress;

        return deployedAddress;
    }

    function createTokenReserveless(
        string memory name,
        string memory symbol,
        bool mintable,
        bool burnable,
        uint256 initialMint,
        uint256 cap,
        string memory identity
    ) external whenNotPaused returns (address) {
        // initialize the ERC20
        bytes memory initialisationArgs = abi.encodeWithSelector(
            ERC20Reserveless.initialize.selector,
            name,
            symbol,
            _msgSender(),
            mintable,
            burnable,
            initialMint,
            cap,
            identity
        );

        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, name));
        address beaconAddress = _getTokenCenterStorage()
            ._tokenReservelessBeacon;
        address predictedAddress = predict(
            beaconAddress,
            salt,
            initialisationArgs
        );

        emit TokenReservelessDeployed(predictedAddress);

        address deployedAddress = address(
            new BeaconProxy{salt: salt}(beaconAddress, initialisationArgs)
        );

        if (deployedAddress != predictedAddress) revert DeployTokenError();
        return deployedAddress;
    }

    function calculateSellOutput(
        uint256 supply,
        uint256 customReserve,
        uint256 customCrr,
        uint256 amountIn
    ) external pure returns (uint256) {
        return _calculateSellOutput(supply, customReserve, customCrr, amountIn); // prettier-ignore
    }

    function calculateSellInput(
        uint256 supply,
        uint256 customReserve,
        uint256 customCrr,
        uint256 amountOut
    ) external pure returns (uint256) {
        return _calculateSellInput(supply, customReserve, customCrr, amountOut); // prettier-ignore
    }

    function calculateBuyOutput(
        uint256 supply,
        uint256 customReserve,
        uint256 customCrr,
        uint256 amountIn
    ) external pure returns (uint256) {
        return
            _calculateBuyOutput(supply, customReserve, customCrr, amountIn); // prettier-ignore
    }

    function calculateBuyInput(
        uint256 supply,
        uint256 customReserve,
        uint256 customCrr,
        uint256 amountOut
    ) external pure returns (uint256) {
        return _calculateBuyInput(supply, customReserve, customCrr, amountOut); // prettier-ignore
    }

    function getCommissionSymbol(
        string memory symbol
    ) public pure returns (uint256) {
        uint256 symbolLen = strlen(symbol);
        if (symbolLen >= 7) return 250 ether;
        if (symbolLen >= 6) return 2500 ether;
        if (symbolLen >= 5) return 25000 ether;
        if (symbolLen >= 4) return 250000 ether;
        if (symbolLen >= 3) return 2500000 ether;
        return 2500000 ether;
    }

    function strlen(string memory s) internal pure returns (uint256) {
        uint256 len;
        uint256 i = 0;
        uint256 bytelength = bytes(s).length;
        for (len = 0; i < bytelength; len++) {
            bytes1 b = bytes(s)[i];
            if (b < 0x80) {
                i += 1;
            } else if (b < 0xE0) {
                i += 2;
            } else if (b < 0xF0) {
                i += 3;
            } else if (b < 0xF8) {
                i += 4;
            } else if (b < 0xFC) {
                i += 5;
            } else {
                i += 6;
            }
        }
        return len;
    }

    function predict(
        address beaconAddress,
        bytes32 salt,
        bytes memory initialisationArgs
    ) public view returns (address) {
        bytes memory bytecode = type(BeaconProxy).creationCode;
        bytes memory creationBytecode = abi.encodePacked(
            bytecode,
            abi.encode(beaconAddress, initialisationArgs)
        );
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                uint256(salt),
                keccak256(creationBytecode)
            )
        );
        return address(uint160(uint256(hash)));
    }

    receive() external payable {}

    /* ========== GETTERS ========== */

    function implementation() public view returns (address) {
        if (paused()) {
            return address(0);
        }
        return _getTokenCenterStorage()._tokenImpl;
    }

    function implementationReserveless() public view returns (address) {
        if (paused()) {
            return address(0);
        }
        return _getTokenCenterStorage()._tokenReservelessImpl;
    }

    function tokens(string memory symbol) public view returns (address) {
        return _getTokenCenterStorage()._tokens[symbol];
    }

    function isTokenExists(address token) public view returns (bool) {
        (bool success, bytes memory res) = token.staticcall(
            abi.encodeWithSelector(IERC20Metadata.symbol.selector)
        );
        if (!success || res.length == 0) {
            return false;
        }
        string memory symbol = abi.decode(res, (string));
        return tokens(symbol) != address(0);
    }

    function getContractCenter() public view returns (address) {
        return _getTokenCenterStorage()._contractCenter;
    }

    /* ========== GOVERNANCE ========== */

    function setContractCenter(address addressContractCenter) public onlyOwner {
        _getTokenCenterStorage()._contractCenter = addressContractCenter;
    }

    function upgrade(address newImpl, bytes memory data) public onlyOwner {
        address currentImpl = ERC1967Utils.getImplementation();

        if (newImpl == address(0) || newImpl == currentImpl)
            revert InvalidAddress();

        ERC1967Utils.upgradeToAndCall(newImpl, data);
    }

    function upgradeToken(address newTokenImpl) public onlyOwner {
        address currentTokenImpl = implementation();

        if (newTokenImpl == address(0)) revert InvalidAddress();
        _getTokenCenterStorage()._tokenImpl = newTokenImpl;

        emit TokenUpgraded(currentTokenImpl, newTokenImpl);
    }

    function upgradeTokenReserveless(address newTokenImpl) public onlyOwner {
        address currentTokenImpl = implementationReserveless();

        if (newTokenImpl == address(0)) revert InvalidAddress();
        _getTokenCenterStorage()._tokenReservelessImpl = newTokenImpl;

        emit TokenReservelessUpgraded(currentTokenImpl, newTokenImpl);
    }

    /* ========== PAUSABLE ========== */

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }
}
