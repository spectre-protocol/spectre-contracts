// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IGrimPool} from "./interfaces/IGrimPool.sol";

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
 * @title GrimSwapRouter
 * @author GrimSwap (github.com/grimswap)
 * @notice Atomic router for private swaps: releases deposited ETH from GrimPool and executes swap
 * @dev Flow: releaseForSwap() -> swap() in one atomic transaction.
 *      If the ZK proof is invalid, the swap reverts, which reverts the ETH release too.
 *
 * Usage:
 *   1. User deposits ETH to GrimPool
 *   2. User generates ZK proof client-side
 *   3. Relayer calls GrimSwapRouter.executePrivateSwap()
 *   4. Router releases ETH from GrimPool -> swaps on Uniswap v4 -> hook routes output to stealth address
 *
 * Partners can also call this router to offer private swaps through their frontends.
 */
contract GrimSwapRouter {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice GrimPool contract that holds deposited ETH
    IGrimPool public immutable grimPool;

    /// @notice Uniswap v4 swap router (PoolSwapTest)
    IPoolSwapTest public immutable swapRouter;

    /// @notice Owner for admin functions
    address public owner;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unauthorized();
    error InvalidAmount();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PrivateSwapRouted(
        address indexed relayer,
        uint256 ethReleased,
        uint256 timestamp
    );

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IGrimPool _grimPool, IPoolSwapTest _swapRouter) {
        grimPool = _grimPool;
        swapRouter = _swapRouter;
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                            SWAP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute a private swap atomically
     * @dev Releases ETH from GrimPool and swaps via Uniswap v4 in one transaction.
     *      The GrimSwapZK hook verifies the ZK proof during the swap.
     *      If proof is invalid, entire transaction reverts (including ETH release).
     * @param key The Uniswap v4 pool key
     * @param params Swap parameters (zeroForOne, amountSpecified, sqrtPriceLimitX96)
     * @param hookData ABI-encoded ZK proof and public signals
     */
    function executePrivateSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external {
        // Calculate ETH needed for the swap input
        uint256 ethAmount = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        if (ethAmount == 0) revert InvalidAmount();

        // Release deposited ETH from GrimPool (reverts if unauthorized or insufficient balance)
        grimPool.releaseForSwap(ethAmount);

        // Execute swap via Uniswap v4 router
        // The GrimSwapZK hook will:
        //   1. Verify ZK proof in beforeSwap
        //   2. Route output tokens to stealth address in afterSwap
        swapRouter.swap{value: ethAmount}(
            key,
            params,
            IPoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        emit PrivateSwapRouted(msg.sender, ethAmount, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Rescue stuck ETH (owner only, for edge cases)
     */
    function rescueETH(address to) external {
        if (msg.sender != owner) revert Unauthorized();
        (bool success, ) = to.call{value: address(this).balance}("");
        require(success, "ETH transfer failed");
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
