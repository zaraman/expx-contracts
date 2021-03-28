// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;

// Needed to pass in structs
pragma experimental ABIEncoderV2;

// Imports

import "./IBEP20.sol";
import "./ICRP.sol";
import "./IEFactory.sol";
import "./EXPXSafeMath.sol";
import "./EXPXSafeApprove.sol";


/**
 * @author EXPX
 * @title Factor out the weight updates
 */
library SmartPoolManager {
    // Type declarations

    struct NewTokenParams {
        address addr;
        bool isCommitted;
        uint commitBlock;
        uint denorm;
        uint balance;
    }

    // For blockwise, automated weight updates
    // Move weights linearly from startWeights to endWeights,
    // between startBlock and endBlock
    struct GradualUpdateParams {
        uint startBlock;
        uint endBlock;
        uint[] startWeights;
        uint[] endWeights;
    }

    // updateWeight and pokeWeights are unavoidably long
    /* solhint-disable function-max-lines */

    /**
     * @notice Update the weight of an existing token
     * @dev Refactored to library to make CRPFactory deployable
     * @param self - ConfigurableRightsPool instance calling the library
     * @param ePool - Core EPool the CRP is wrapping
     * @param token - token to be reweighted
     * @param newWeight - new weight of the token
    */
    function updateWeight(
        IConfigurableRightsPool self,
        IEPool ePool,
        address token,
        uint newWeight
    )
    external
    {
        require(newWeight >= EXPXConstants.MIN_WEIGHT, "ERR_MIN_WEIGHT");
        require(newWeight <= EXPXConstants.MAX_WEIGHT, "ERR_MAX_WEIGHT");

        uint currentWeight = ePool.getDenormalizedWeight(token);
        // Save gas; return immediately on NOOP
        if (currentWeight == newWeight) {
            return;
        }

        uint currentBalance = ePool.getBalance(token);
        uint totalSupply = self.totalSupply();
        uint totalWeight = ePool.getTotalDenormalizedWeight();
        uint poolShares;
        uint deltaBalance;
        uint deltaWeight;
        uint newBalance;

        if (newWeight < currentWeight) {
            // This means the controller will withdraw tokens to keep price
            // So they need to redeem PCTokens
            deltaWeight = EXPXSafeMath.eSub(currentWeight, newWeight);

            // poolShares = totalSupply * (deltaWeight / totalWeight)
            poolShares = EXPXSafeMath.eMul(totalSupply,
                EXPXSafeMath.eDiv(deltaWeight, totalWeight));

            // deltaBalance = currentBalance * (deltaWeight / currentWeight)
            deltaBalance = EXPXSafeMath.eMul(currentBalance,
                EXPXSafeMath.eDiv(deltaWeight, currentWeight));

            // New balance cannot be lower than MIN_BALANCE
            newBalance = EXPXSafeMath.eSub(currentBalance, deltaBalance);

            require(newBalance >= EXPXConstants.MIN_BALANCE, "ERR_MIN_BALANCE");

            // First get the tokens from this contract (Pool Controller) to msg.sender
            ePool.rebind(token, newBalance, newWeight);

            // Now with the tokens this contract can send them to msg.sender
            bool xfer = IBEP20(token).transfer(msg.sender, deltaBalance);
            require(xfer, "ERR_BEP20_FALSE");

            self.pullPoolShareFromLib(msg.sender, poolShares);
            self.burnPoolShareFromLib(poolShares);
        }
        else {
            // This means the controller will deposit tokens to keep the price.
            // They will be minted and given PCTokens
            deltaWeight = EXPXSafeMath.eSub(newWeight, currentWeight);

            require(EXPXSafeMath.eAdd(totalWeight, deltaWeight) <= EXPXConstants.MAX_TOTAL_WEIGHT,
                "ERR_MAX_TOTAL_WEIGHT");

            // poolShares = totalSupply * (deltaWeight / totalWeight)
            poolShares = EXPXSafeMath.eMul(totalSupply,
                EXPXSafeMath.eDiv(deltaWeight, totalWeight));
            // deltaBalance = currentBalance * (deltaWeight / currentWeight)
            deltaBalance = EXPXSafeMath.eMul(currentBalance,
                EXPXSafeMath.eDiv(deltaWeight, currentWeight));

            // First gets the tokens from msg.sender to this contract (Pool Controller)
            bool xfer = IBEP20(token).transferFrom(msg.sender, address(this), deltaBalance);
            require(xfer, "ERR_BEP20_FALSE");

            // Now with the tokens this contract can bind them to the pool it controls
            ePool.rebind(token, EXPXSafeMath.eAdd(currentBalance, deltaBalance), newWeight);

            self.mintPoolShareFromLib(poolShares);
            self.pushPoolShareFromLib(msg.sender, poolShares);
        }
    }

    /**
     * @notice External function called to make the contract update weights according to plan
     * @param ePool - Core EPool the CRP is wrapping
     * @param gradualUpdate - gradual update parameters from the CRP
    */
    function pokeWeights(
        IEPool ePool,
        GradualUpdateParams storage gradualUpdate
    )
    external
    {
        // Do nothing if we call this when there is no update plan
        if (gradualUpdate.startBlock == 0) {
            return;
        }

        // Error to call it before the start of the plan
        require(block.number >= gradualUpdate.startBlock, "ERR_CANT_POKE_YET");
        // Proposed error message improvement
        // require(block.number >= startBlock, "ERR_NO_HOKEY_POKEY");

        // This allows for pokes after endBlock that get weights to endWeights
        // Get the current block (or the endBlock, if we're already past the end)
        uint currentBlock;
        if (block.number > gradualUpdate.endBlock) {
            currentBlock = gradualUpdate.endBlock;
        }
        else {
            currentBlock = block.number;
        }

        uint blockPeriod = EXPXSafeMath.eSub(gradualUpdate.endBlock, gradualUpdate.startBlock);
        uint blocksElapsed = EXPXSafeMath.eSub(currentBlock, gradualUpdate.startBlock);
        uint weightDelta;
        uint deltaPerBlock;
        uint newWeight;

        address[] memory tokens = ePool.getCurrentTokens();

        // This loop contains external calls
        // External calls are to math libraries or the underlying pool, so low risk
        for (uint i = 0; i < tokens.length; i++) {
            // Make sure it does nothing if the new and old weights are the same (saves gas)
            // It's a degenerate case if they're *all* the same, but you certainly could have
            // a plan where you only change some of the weights in the set
            if (gradualUpdate.startWeights[i] != gradualUpdate.endWeights[i]) {
                if (gradualUpdate.endWeights[i] < gradualUpdate.startWeights[i]) {
                    // We are decreasing the weight

                    // First get the total weight delta
                    weightDelta = EXPXSafeMath.eSub(gradualUpdate.startWeights[i],
                        gradualUpdate.endWeights[i]);
                    // And the amount it should change per block = total change/number of blocks in the period
                    deltaPerBlock = EXPXSafeMath.eDiv(weightDelta, blockPeriod);
                    //deltaPerBlock = eDiv(weightDelta, blockPeriod);

                    // newWeight = startWeight - (blocksElapsed * deltaPerBlock)
                    newWeight = EXPXSafeMath.eSub(gradualUpdate.startWeights[i],
                        EXPXSafeMath.eMul(blocksElapsed, deltaPerBlock));
                }
                else {
                    // We are increasing the weight

                    // First get the total weight delta
                    weightDelta = EXPXSafeMath.eSub(gradualUpdate.endWeights[i],
                        gradualUpdate.startWeights[i]);
                    // And the amount it should change per block = total change/number of blocks in the period
                    deltaPerBlock = EXPXSafeMath.eDiv(weightDelta, blockPeriod);
                    //deltaPerBlock = eDiv(weightDelta, blockPeriod);

                    // newWeight = startWeight + (blocksElapsed * deltaPerBlock)
                    newWeight = EXPXSafeMath.eAdd(gradualUpdate.startWeights[i],
                        EXPXSafeMath.eMul(blocksElapsed, deltaPerBlock));
                }

                uint bal = ePool.getBalance(tokens[i]);

                ePool.rebind(tokens[i], bal, newWeight);
            }
        }

        // Reset to allow add/remove tokens, or manual weight updates
        if (block.number >= gradualUpdate.endBlock) {
            gradualUpdate.startBlock = 0;
        }
    }

    /* solhint-enable function-max-lines */

    /**
     * @notice Schedule (commit) a token to be added; must call applyAddToken after a fixed
     *         number of blocks to actually add the token
     * @param ePool - Core EPool the CRP is wrapping
     * @param token - the token to be added
     * @param balance - how much to be added
     * @param denormalizedWeight - the desired token weight
     * @param newToken - NewTokenParams struct used to hold the token data (in CRP storage)
     */
    function commitAddToken(
        IEPool ePool,
        address token,
        uint balance,
        uint denormalizedWeight,
        NewTokenParams storage newToken
    )
    external
    {
        require(!ePool.isBound(token), "ERR_IS_BOUND");

        require(denormalizedWeight <= EXPXConstants.MAX_WEIGHT, "ERR_WEIGHT_ABOVE_MAX");
        require(denormalizedWeight >= EXPXConstants.MIN_WEIGHT, "ERR_WEIGHT_BELOW_MIN");
        require(EXPXSafeMath.eAdd(ePool.getTotalDenormalizedWeight(),
            denormalizedWeight) <= EXPXConstants.MAX_TOTAL_WEIGHT,
            "ERR_MAX_TOTAL_WEIGHT");
        require(balance >= EXPXConstants.MIN_BALANCE, "ERR_BALANCE_BELOW_MIN");

        newToken.addr = token;
        newToken.balance = balance;
        newToken.denorm = denormalizedWeight;
        newToken.commitBlock = block.number;
        newToken.isCommitted = true;
    }

    /**
     * @notice Add the token previously committed (in commitAddToken) to the pool
     * @param self - ConfigurableRightsPool instance calling the library
     * @param ePool - Core EPool the CRP is wrapping
     * @param addTokenTimeLockInBlocks -  Wait time between committing and applying a new token
     * @param newToken - NewTokenParams struct used to hold the token data (in CRP storage)
     */
    function applyAddToken(
        IConfigurableRightsPool self,
        IEPool ePool,
        uint addTokenTimeLockInBlocks,
        NewTokenParams storage newToken
    )
    external
    {
        require(newToken.isCommitted, "ERR_NO_TOKEN_COMMIT");
        require(EXPXSafeMath.eSub(block.number, newToken.commitBlock) >= addTokenTimeLockInBlocks,
            "ERR_TIMELOCK_STILL_COUNTING");

        uint totalSupply = self.totalSupply();

        // poolShares = totalSupply * newTokenWeight / totalWeight
        uint poolShares = EXPXSafeMath.eDiv(EXPXSafeMath.eMul(totalSupply, newToken.denorm),
            ePool.getTotalDenormalizedWeight());

        // Clear this to allow adding more tokens
        newToken.isCommitted = false;

        // First gets the tokens from msg.sender to this contract (Pool Controller)
        bool returnValue = IBEP20(newToken.addr).transferFrom(self.getController(), address(self), newToken.balance);
        require(returnValue, "ERR_BEP20_FALSE");

        // Now with the tokens this contract can bind them to the pool it controls
        // Approves ePool to pull from this controller
        // Approve unlimited, same as when creating the pool, so they can join pools later
        returnValue = EXPXSafeApprove.safeApprove(IBEP20(newToken.addr), address(ePool), EXPXConstants.MAX_UINT);
        require(returnValue, "ERR_BEP20_FALSE");

        ePool.bind(newToken.addr, newToken.balance, newToken.denorm);

        self.mintPoolShareFromLib(poolShares);
        self.pushPoolShareFromLib(msg.sender, poolShares);
    }

    /**
    * @notice Remove a token from the pool
    * @dev Logic in the CRP controls when ths can be called. There are two related permissions:
    *      AddRemoveTokens - which allows removing down to the underlying EPool limit of two
    *      RemoveAllTokens - which allows completely draining the pool by removing all tokens
    *                        This can result in a non-viable pool with 0 or 1 tokens (by design),
    *                        meaning all swapping or binding operations would fail in this state
    * @param self - ConfigurableRightsPool instance calling the library
    * @param ePool - Core EPool the CRP is wrapping
    * @param token - token to remove
    */
    function removeToken(
        IConfigurableRightsPool self,
        IEPool ePool,
        address token
    )
    external
    {
        uint totalSupply = self.totalSupply();

        // poolShares = totalSupply * tokenWeight / totalWeight
        uint poolShares = EXPXSafeMath.eDiv(EXPXSafeMath.eMul(totalSupply,
            ePool.getDenormalizedWeight(token)),
            ePool.getTotalDenormalizedWeight());

        // this is what will be unbound from the pool
        // Have to get it before unbinding
        uint balance = ePool.getBalance(token);

        // Unbind and get the tokens out of expx pool
        ePool.unbind(token);

        // Now with the tokens this contract can send them to msg.sender
        bool xfer = IBEP20(token).transfer(self.getController(), balance);
        require(xfer, "ERR_BEP20_FALSE");

        self.pullPoolShareFromLib(self.getController(), poolShares);
        self.burnPoolShareFromLib(poolShares);
    }

    /**
     * @notice Non BEP20-conforming tokens are problematic; don't allow them in pools
     * @dev Will revert if invalid
     * @param token - The prospective token to verify
     */
    function verifyTokenCompliance(address token) external {
        verifyTokenComplianceInternal(token);
    }

    /**
     * @notice Non BEP20-conforming tokens are problematic; don't allow them in pools
     * @dev Will revert if invalid - overloaded to save space in the main contract
     * @param tokens - The prospective tokens to verify
     */
    function verifyTokenCompliance(address[] calldata tokens) external {
        for (uint i = 0; i < tokens.length; i++) {
            verifyTokenComplianceInternal(tokens[i]);
        }
    }

    /**
     * @notice Update weights in a predetermined way, between startBlock and endBlock,
     *         through external cals to pokeWeights
     * @param ePool - Core EPool the CRP is wrapping
     * @param newWeights - final weights we want to get to
     * @param startBlock - when weights should start to change
     * @param endBlock - when weights will be at their final values
     * @param minimumWeightChangeBlockPeriod - needed to validate the block period
    */
    function updateWeightsGradually(
        IEPool ePool,
        GradualUpdateParams storage gradualUpdate,
        uint[] calldata newWeights,
        uint startBlock,
        uint endBlock,
        uint minimumWeightChangeBlockPeriod
    )
    external
    {
        require(block.number < endBlock, "ERR_GRADUAL_UPDATE_TIME_TRAVEL");

        if (block.number > startBlock) {
            // This means the weight update should start ASAP
            // Moving the start block up prevents a big jump/discontinuity in the weights
            gradualUpdate.startBlock = block.number;
        }
        else{
            gradualUpdate.startBlock = startBlock;
        }

        // Enforce a minimum time over which to make the changes
        // The also prevents endBlock <= startBlock
        require(EXPXSafeMath.eSub(endBlock, gradualUpdate.startBlock) >= minimumWeightChangeBlockPeriod,
            "ERR_WEIGHT_CHANGE_TIME_BELOW_MIN");

        address[] memory tokens = ePool.getCurrentTokens();

        // Must specify weights for all tokens
        require(newWeights.length == tokens.length, "ERR_START_WEIGHTS_MISMATCH");

        uint weightsSum = 0;
        gradualUpdate.startWeights = new uint[](tokens.length);

        // Check that endWeights are valid now to avoid reverting in a future pokeWeights call
        //
        // This loop contains external calls
        // External calls are to math libraries or the underlying pool, so low risk
        for (uint i = 0; i < tokens.length; i++) {
            require(newWeights[i] <= EXPXConstants.MAX_WEIGHT, "ERR_WEIGHT_ABOVE_MAX");
            require(newWeights[i] >= EXPXConstants.MIN_WEIGHT, "ERR_WEIGHT_BELOW_MIN");

            weightsSum = EXPXSafeMath.eAdd(weightsSum, newWeights[i]);
            gradualUpdate.startWeights[i] = ePool.getDenormalizedWeight(tokens[i]);
        }
        require(weightsSum <= EXPXConstants.MAX_TOTAL_WEIGHT, "ERR_MAX_TOTAL_WEIGHT");

        gradualUpdate.endBlock = endBlock;
        gradualUpdate.endWeights = newWeights;
    }

    /**
     * @notice Join a pool
     * @param self - ConfigurableRightsPool instance calling the library
     * @param ePool - Core EPool the CRP is wrapping
     * @param poolAmountOut - number of pool tokens to receive
     * @param maxAmountsIn - Max amount of asset tokens to spend
     * @return actualAmountsIn - calculated values of the tokens to pull in
     */
    function joinPool(
        IConfigurableRightsPool self,
        IEPool ePool,
        uint poolAmountOut,
        uint[] calldata maxAmountsIn
    )
    external
    view
    returns (uint[] memory actualAmountsIn)
    {
        address[] memory tokens = ePool.getCurrentTokens();

        require(maxAmountsIn.length == tokens.length, "ERR_AMOUNTS_MISMATCH");

        uint poolTotal = self.totalSupply();
        // Subtract  1 to ensure any rounding errors favor the pool
        uint ratio = EXPXSafeMath.eDiv(poolAmountOut,
            EXPXSafeMath.eSub(poolTotal, 1));

        require(ratio != 0, "ERR_MATH_APPROX");

        // We know the length of the array; initialize it, and fill it below
        // Cannot do "push" in memory
        actualAmountsIn = new uint[](tokens.length);

        // This loop contains external calls
        // External calls are to math libraries or the underlying pool, so low risk
        for (uint i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            uint bal = ePool.getBalance(t);
            // Add 1 to ensure any rounding errors favor the pool
            uint tokenAmountIn = EXPXSafeMath.eMul(ratio,
                EXPXSafeMath.eAdd(bal, 1));

            require(tokenAmountIn != 0, "ERR_MATH_APPROX");
            require(tokenAmountIn <= maxAmountsIn[i], "ERR_LIMIT_IN");

            actualAmountsIn[i] = tokenAmountIn;
        }
    }

    /**
     * @notice Exit a pool - redeem pool tokens for underlying assets
     * @param self - ConfigurableRightsPool instance calling the library
     * @param ePool - Core EPool the CRP is wrapping
     * @param poolAmountIn - amount of pool tokens to redeem
     * @param minAmountsOut - minimum amount of asset tokens to receive
     * @return exitFee - calculated exit fee
     * @return pAiAfterExitFee - final amount in (after accounting for exit fee)
     * @return actualAmountsOut - calculated amounts of each token to pull
     */
    function exitPool(
        IConfigurableRightsPool self,
        IEPool ePool,
        uint poolAmountIn,
        uint[] calldata minAmountsOut
    )
    external
    view
    returns (uint exitFee, uint pAiAfterExitFee, uint[] memory actualAmountsOut)
    {
        address[] memory tokens = ePool.getCurrentTokens();

        require(minAmountsOut.length == tokens.length, "ERR_AMOUNTS_MISMATCH");

        uint poolTotal = self.totalSupply();

        // Calculate exit fee and the final amount in
        exitFee = EXPXSafeMath.eMul(poolAmountIn, EXPXConstants.EXIT_FEE);
        pAiAfterExitFee = EXPXSafeMath.eSub(poolAmountIn, exitFee);

        uint ratio = EXPXSafeMath.eDiv(pAiAfterExitFee,
            EXPXSafeMath.eAdd(poolTotal, 1));

        require(ratio != 0, "ERR_MATH_APPROX");

        actualAmountsOut = new uint[](tokens.length);

        // This loop contains external calls
        // External calls are to math libraries or the underlying pool, so low risk
        for (uint i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            uint bal = ePool.getBalance(t);
            // Subtract 1 to ensure any rounding errors favor the pool
            uint tokenAmountOut = EXPXSafeMath.eMul(ratio,
                EXPXSafeMath.eSub(bal, 1));

            require(tokenAmountOut != 0, "ERR_MATH_APPROX");
            require(tokenAmountOut >= minAmountsOut[i], "ERR_LIMIT_OUT");

            actualAmountsOut[i] = tokenAmountOut;
        }
    }

    /**
     * @notice Join by swapping a fixed amount of an external token in (must be present in the pool)
     *         System calculates the pool token amount
     * @param self - ConfigurableRightsPool instance calling the library
     * @param ePool - Core EPool the CRP is wrapping
     * @param tokenIn - which token we're transferring in
     * @param tokenAmountIn - amount of deposit
     * @param minPoolAmountOut - minimum of pool tokens to receive
     * @return poolAmountOut - amount of pool tokens minted and transferred
     */
    function joinswapExternAmountIn(
        IConfigurableRightsPool self,
        IEPool ePool,
        address tokenIn,
        uint tokenAmountIn,
        uint minPoolAmountOut
    )
    external
    view
    returns (uint poolAmountOut)
    {
        require(ePool.isBound(tokenIn), "ERR_NOT_BOUND");
        require(tokenAmountIn <= EXPXSafeMath.eMul(ePool.getBalance(tokenIn),
            EXPXConstants.MAX_IN_RATIO),
            "ERR_MAX_IN_RATIO");

        poolAmountOut = ePool.calcPoolOutGivenSingleIn(
            ePool.getBalance(tokenIn),
            ePool.getDenormalizedWeight(tokenIn),
            self.totalSupply(),
            ePool.getTotalDenormalizedWeight(),
            tokenAmountIn,
            ePool.getSwapFee()
        );

        require(poolAmountOut >= minPoolAmountOut, "ERR_LIMIT_OUT");
    }

    /**
     * @notice Join by swapping an external token in (must be present in the pool)
     *         To receive an exact amount of pool tokens out. System calculates the deposit amount
     * @param self - ConfigurableRightsPool instance calling the library
     * @param ePool - Core EPool the CRP is wrapping
     * @param tokenIn - which token we're transferring in (system calculates amount required)
     * @param poolAmountOut - amount of pool tokens to be received
     * @param maxAmountIn - Maximum asset tokens that can be pulled to pay for the pool tokens
     * @return tokenAmountIn - amount of asset tokens transferred in to purchase the pool tokens
     */
    function joinswapPoolAmountOut(
        IConfigurableRightsPool self,
        IEPool ePool,
        address tokenIn,
        uint poolAmountOut,
        uint maxAmountIn
    )
    external
    view
    returns (uint tokenAmountIn)
    {
        require(ePool.isBound(tokenIn), "ERR_NOT_BOUND");

        tokenAmountIn = ePool.calcSingleInGivenPoolOut(
            ePool.getBalance(tokenIn),
            ePool.getDenormalizedWeight(tokenIn),
            self.totalSupply(),
            ePool.getTotalDenormalizedWeight(),
            poolAmountOut,
            ePool.getSwapFee()
        );

        require(tokenAmountIn != 0, "ERR_MATH_APPROX");
        require(tokenAmountIn <= maxAmountIn, "ERR_LIMIT_IN");

        require(tokenAmountIn <= EXPXSafeMath.eMul(ePool.getBalance(tokenIn),
            EXPXConstants.MAX_IN_RATIO),
            "ERR_MAX_IN_RATIO");
    }

    /**
     * @notice Exit a pool - redeem a specific number of pool tokens for an underlying asset
     *         Asset must be present in the pool, and will incur an EXIT_FEE (if set to non-zero)
     * @param self - ConfigurableRightsPool instance calling the library
     * @param ePool - Core EPool the CRP is wrapping
     * @param tokenOut - which token the caller wants to receive
     * @param poolAmountIn - amount of pool tokens to redeem
     * @param minAmountOut - minimum asset tokens to receive
     * @return exitFee - calculated exit fee
     * @return tokenAmountOut - amount of asset tokens returned
     */
    function exitswapPoolAmountIn(
        IConfigurableRightsPool self,
        IEPool ePool,
        address tokenOut,
        uint poolAmountIn,
        uint minAmountOut
    )
    external
    view
    returns (uint exitFee, uint tokenAmountOut)
    {
        require(ePool.isBound(tokenOut), "ERR_NOT_BOUND");

        tokenAmountOut = ePool.calcSingleOutGivenPoolIn(
            ePool.getBalance(tokenOut),
            ePool.getDenormalizedWeight(tokenOut),
            self.totalSupply(),
            ePool.getTotalDenormalizedWeight(),
            poolAmountIn,
            ePool.getSwapFee()
        );

        require(tokenAmountOut >= minAmountOut, "ERR_LIMIT_OUT");
        require(tokenAmountOut <= EXPXSafeMath.eMul(ePool.getBalance(tokenOut),
            EXPXConstants.MAX_OUT_RATIO),
            "ERR_MAX_OUT_RATIO");

        exitFee = EXPXSafeMath.eMul(poolAmountIn, EXPXConstants.EXIT_FEE);
    }

    /**
     * @notice Exit a pool - redeem pool tokens for a specific amount of underlying assets
     *         Asset must be present in the pool
     * @param self - ConfigurableRightsPool instance calling the library
     * @param ePool - Core EPool the CRP is wrapping
     * @param tokenOut - which token the caller wants to receive
     * @param tokenAmountOut - amount of underlying asset tokens to receive
     * @param maxPoolAmountIn - maximum pool tokens to be redeemed
     * @return exitFee - calculated exit fee
     * @return poolAmountIn - amount of pool tokens redeemed
     */
    function exitswapExternAmountOut(
        IConfigurableRightsPool self,
        IEPool ePool,
        address tokenOut,
        uint tokenAmountOut,
        uint maxPoolAmountIn
    )
    external
    view
    returns (uint exitFee, uint poolAmountIn)
    {
        require(ePool.isBound(tokenOut), "ERR_NOT_BOUND");
        require(tokenAmountOut <= EXPXSafeMath.eMul(ePool.getBalance(tokenOut),
            EXPXConstants.MAX_OUT_RATIO),
            "ERR_MAX_OUT_RATIO");
        poolAmountIn = ePool.calcPoolInGivenSingleOut(
            ePool.getBalance(tokenOut),
            ePool.getDenormalizedWeight(tokenOut),
            self.totalSupply(),
            ePool.getTotalDenormalizedWeight(),
            tokenAmountOut,
            ePool.getSwapFee()
        );

        require(poolAmountIn != 0, "ERR_MATH_APPROX");
        require(poolAmountIn <= maxPoolAmountIn, "ERR_LIMIT_IN");

        exitFee = EXPXSafeMath.eMul(poolAmountIn, EXPXConstants.EXIT_FEE);
    }

    // Internal functions

    // Check for zero transfer, and make sure it returns true to returnValue
    function verifyTokenComplianceInternal(address token) internal {
        bool returnValue = IBEP20(token).transfer(msg.sender, 0);
        require(returnValue, "ERR_NONCONFORMING_TOKEN");
    }
}