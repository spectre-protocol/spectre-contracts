// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IGrimPoolMultiToken
 * @notice Interface for multi-token GrimPool
 */
interface IGrimPoolMultiToken {
    function releaseForSwap(uint256 amount) external;
    function releaseTokenForSwap(address token, uint256 amount) external;
}

/**
 * @title IPoolSwapTest
 * @notice Interface for Uniswap v4 PoolSwapTest router
 */
interface IPoolSwapTest {
    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        TestSettings calldata testSettings,
        bytes calldata hookData
    ) external payable returns (int256);
}

/**
 * @title GrimSwapRouterV2
 * @author GrimSwap (github.com/grimswap)
 * @notice Atomic router for private swaps supporting both ETH and ERC20 deposits
 * @dev Flow: releaseForSwap/releaseTokenForSwap -> swap in one atomic transaction.
 *      If the ZK proof is invalid, the swap reverts, which reverts the release too.
 */
contract GrimSwapRouterV2 {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice GrimPoolMultiToken contract that holds deposited funds
    IGrimPoolMultiToken public immutable grimPool;

    /// @notice Uniswap v4 swap router (PoolSwapTest)
    IPoolSwapTest public immutable swapRouter;

    /// @notice Owner for admin functions
    address public owner;

    /// @notice Address representing native ETH
    address public constant ETH_ADDRESS = address(0);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unauthorized();
    error InvalidAmount();
    error InvalidToken();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PrivateSwapRouted(
        address indexed relayer,
        address indexed token,
        uint256 amountReleased,
        uint256 timestamp
    );

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IGrimPoolMultiToken _grimPool, IPoolSwapTest _swapRouter) {
        grimPool = _grimPool;
        swapRouter = _swapRouter;
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                            SWAP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute a private swap with ETH (backwards compatible)
     * @param key The Uniswap v4 pool key
     * @param params Swap parameters
     * @param hookData ABI-encoded ZK proof and public signals
     */
    function executePrivateSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external {
        _executeSwapWithETH(key, params, hookData);
    }

    /**
     * @notice Execute a private swap with ERC20 token
     * @param key The Uniswap v4 pool key
     * @param params Swap parameters
     * @param inputToken The ERC20 token being swapped from
     * @param hookData ABI-encoded ZK proof and public signals
     */
    function executePrivateSwapToken(
        PoolKey calldata key,
        SwapParams calldata params,
        address inputToken,
        bytes calldata hookData
    ) external {
        if (inputToken == ETH_ADDRESS) {
            _executeSwapWithETH(key, params, hookData);
        } else {
            _executeSwapWithToken(key, params, inputToken, hookData);
        }
    }

    /**
     * @notice Internal: Execute swap with ETH
     */
    function _executeSwapWithETH(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal {
        uint256 ethAmount = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        if (ethAmount == 0) revert InvalidAmount();

        // Release deposited ETH from GrimPool
        grimPool.releaseForSwap(ethAmount);

        // Execute swap via Uniswap v4 router
        swapRouter.swap{value: ethAmount}(
            key,
            params,
            IPoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        emit PrivateSwapRouted(msg.sender, ETH_ADDRESS, ethAmount, block.timestamp);
    }

    /**
     * @notice Internal: Execute swap with ERC20 token
     */
    function _executeSwapWithToken(
        PoolKey calldata key,
        SwapParams calldata params,
        address inputToken,
        bytes calldata hookData
    ) internal {
        uint256 tokenAmount = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        if (tokenAmount == 0) revert InvalidAmount();

        // Release deposited tokens from GrimPool
        grimPool.releaseTokenForSwap(inputToken, tokenAmount);

        // Approve swap router to spend tokens
        IERC20(inputToken).safeIncreaseAllowance(address(swapRouter), tokenAmount);

        // Execute swap via Uniswap v4 router (no ETH value for ERC20 swaps)
        swapRouter.swap(
            key,
            params,
            IPoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        emit PrivateSwapRouted(msg.sender, inputToken, tokenAmount, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Rescue stuck ETH (owner only)
     */
    function rescueETH(address to) external {
        if (msg.sender != owner) revert Unauthorized();
        (bool success, ) = to.call{value: address(this).balance}("");
        require(success, "ETH transfer failed");
    }

    /**
     * @notice Rescue stuck ERC20 tokens (owner only)
     */
    function rescueToken(address token, address to) external {
        if (msg.sender != owner) revert Unauthorized();
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, balance);
    }

    /**
     * @notice Transfer ownership
     */
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        owner = newOwner;
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow contract to receive ETH from GrimPool
    receive() external payable {}
}
