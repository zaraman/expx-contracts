// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.5.12;

import "./ENum.sol";

contract EMath is EBronze, EConst, ENum {
    /**********************************************************************************************
    // calcSpotPrice                                                                             //
    // sP = spotPrice                                                                            //
    // bI = tokenBalanceIn                ( bI / wI )         1                                  //
    // bO = tokenBalanceOut         sP =  -----------  *  ----------                             //
    // wI = tokenWeightIn                 ( bO / wO )     ( 1 - sF )                             //
    // wO = tokenWeightOut                                                                       //
    // sF = swapFee                                                                              //
    **********************************************************************************************/
    function calcSpotPrice(
        uint tokenBalanceIn,
        uint tokenWeightIn,
        uint tokenBalanceOut,
        uint tokenWeightOut,
        uint swapFee
    )
    public pure
    returns (uint spotPrice)
    {
        uint numer = eDiv(tokenBalanceIn, tokenWeightIn);
        uint denom = eDiv(tokenBalanceOut, tokenWeightOut);
        uint ratio = eDiv(numer, denom);
        uint scale = eDiv(EONE, eSub(EONE, swapFee));
        return  (spotPrice = eMul(ratio, scale));
    }

    /**********************************************************************************************
    // calcOutGivenIn                                                                            //
    // aO = tokenAmountOut                                                                       //
    // bO = tokenBalanceOut                                                                      //
    // bI = tokenBalanceIn              /      /            bI             \    (wI / wO) \      //
    // aI = tokenAmountIn    aO = bO * |  1 - | --------------------------  | ^            |     //
    // wI = tokenWeightIn               \      \ ( bI + ( aI * ( 1 - sF )) /              /      //
    // wO = tokenWeightOut                                                                       //
    // sF = swapFee                                                                              //
    **********************************************************************************************/
    function calcOutGivenIn(
        uint tokenBalanceIn,
        uint tokenWeightIn,
        uint tokenBalanceOut,
        uint tokenWeightOut,
        uint tokenAmountIn,
        uint swapFee
    )
    public pure
    returns (uint tokenAmountOut)
    {
        uint weightRatio = eDiv(tokenWeightIn, tokenWeightOut);
        uint adjustedIn = eSub(EONE, swapFee);
        adjustedIn = eMul(tokenAmountIn, adjustedIn);
        uint y = eDiv(tokenBalanceIn, eAdd(tokenBalanceIn, adjustedIn));
        uint foo = ePow(y, weightRatio);
        uint bar = eSub(EONE, foo);
        tokenAmountOut = eMul(tokenBalanceOut, bar);
        return tokenAmountOut;
    }

    /**********************************************************************************************
    // calcInGivenOut                                                                            //
    // aI = tokenAmountIn                                                                        //
    // bO = tokenBalanceOut               /  /     bO      \    (wO / wI)      \                 //
    // bI = tokenBalanceIn          bI * |  | ------------  | ^            - 1  |                //
    // aO = tokenAmountOut    aI =        \  \ ( bO - aO ) /                   /                 //
    // wI = tokenWeightIn           --------------------------------------------                 //
    // wO = tokenWeightOut                          ( 1 - sF )                                   //
    // sF = swapFee                                                                              //
    **********************************************************************************************/
    function calcInGivenOut(
        uint tokenBalanceIn,
        uint tokenWeightIn,
        uint tokenBalanceOut,
        uint tokenWeightOut,
        uint tokenAmountOut,
        uint swapFee
    )
    public pure
    returns (uint tokenAmountIn)
    {
        uint weightRatio = eDiv(tokenWeightOut, tokenWeightIn);
        uint diff = eSub(tokenBalanceOut, tokenAmountOut);
        uint y = eDiv(tokenBalanceOut, diff);
        uint foo = ePow(y, weightRatio);
        foo = eSub(foo, EONE);
        tokenAmountIn = eSub(EONE, swapFee);
        tokenAmountIn = eDiv(eMul(tokenBalanceIn, foo), tokenAmountIn);
        return tokenAmountIn;
    }

    /**********************************************************************************************
    // calcPoolOutGivenSingleIn                                                                  //
    // pAo = poolAmountOut         /                                              \              //
    // tAi = tokenAmountIn        ///      /     //    wI \      \\       \     wI \             //
    // wI = tokenWeightIn        //| tAi *| 1 - || 1 - --  | * sF || + tBi \    --  \            //
    // tW = totalWeight     pAo=||  \      \     \\    tW /      //         | ^ tW   | * pS - pS //
    // tBi = tokenBalanceIn      \\  ------------------------------------- /        /            //
    // pS = poolSupply            \\                    tBi               /        /             //
    // sF = swapFee                \                                              /              //
    **********************************************************************************************/
    function calcPoolOutGivenSingleIn(
        uint tokenBalanceIn,
        uint tokenWeightIn,
        uint poolSupply,
        uint totalWeight,
        uint tokenAmountIn,
        uint swapFee
    )
    public pure
    returns (uint poolAmountOut)
    {
        // Charge the trading fee for the proportion of tokenAi
        ///  which is implicitly traded to the other pool tokens.
        // That proportion is (1- weightTokenIn)
        // tokenAiAfterFee = tAi * (1 - (1-weightTi) * poolFee);
        uint normalizedWeight = eDiv(tokenWeightIn, totalWeight);
        uint zaz = eMul(eSub(EONE, normalizedWeight), swapFee);
        uint tokenAmountInAfterFee = eMul(tokenAmountIn, eSub(EONE, zaz));

        uint newTokenBalanceIn = eAdd(tokenBalanceIn, tokenAmountInAfterFee);
        uint tokenInRatio = eDiv(newTokenBalanceIn, tokenBalanceIn);

        // uint newPoolSupply = (ratioTi ^ weightTi) * poolSupply;
        uint poolRatio = ePow(tokenInRatio, normalizedWeight);
        uint newPoolSupply = eMul(poolRatio, poolSupply);
        poolAmountOut = eSub(newPoolSupply, poolSupply);
        return poolAmountOut;
    }

    /**********************************************************************************************
    // calcSingleInGivenPoolOut                                                                  //
    // tAi = tokenAmountIn              //(pS + pAo)\     /    1    \\                           //
    // pS = poolSupply                 || ---------  | ^ | --------- || * bI - bI                //
    // pAo = poolAmountOut              \\    pS    /     \(wI / tW)//                           //
    // bI = balanceIn          tAi =  --------------------------------------------               //
    // wI = weightIn                              /      wI  \                                   //
    // tW = totalWeight                          |  1 - ----  |  * sF                            //
    // sF = swapFee                               \      tW  /                                   //
    **********************************************************************************************/
    function calcSingleInGivenPoolOut(
        uint tokenBalanceIn,
        uint tokenWeightIn,
        uint poolSupply,
        uint totalWeight,
        uint poolAmountOut,
        uint swapFee
    )
    public pure
    returns (uint tokenAmountIn)
    {
        uint normalizedWeight = eDiv(tokenWeightIn, totalWeight);
        uint newPoolSupply = eAdd(poolSupply, poolAmountOut);
        uint poolRatio = eDiv(newPoolSupply, poolSupply);

        //uint newBalTi = poolRatio^(1/weightTi) * balTi;
        uint boo = eDiv(EONE, normalizedWeight);
        uint tokenInRatio = ePow(poolRatio, boo);
        uint newTokenBalanceIn = eMul(tokenInRatio, tokenBalanceIn);
        uint tokenAmountInAfterFee = eSub(newTokenBalanceIn, tokenBalanceIn);
        // Do reverse order of fees charged in joinswap_ExternAmountIn, this way
        //     ``` pAo == joinswap_ExternAmountIn(Ti, joinswap_PoolAmountOut(pAo, Ti)) ```
        //uint tAi = tAiAfterFee / (1 - (1-weightTi) * swapFee) ;
        uint zar = eMul(eSub(EONE, normalizedWeight), swapFee);
        tokenAmountIn = eDiv(tokenAmountInAfterFee, eSub(EONE, zar));
        return tokenAmountIn;
    }

    /**********************************************************************************************
    // calcSingleOutGivenPoolIn                                                                  //
    // tAo = tokenAmountOut            /      /                                             \\   //
    // bO = tokenBalanceOut           /      // pS - (pAi * (1 - eF)) \     /    1    \      \\  //
    // pAi = poolAmountIn            | bO - || ----------------------- | ^ | --------- | * b0 || //
    // ps = poolSupply                \      \\          pS           /     \(wO / tW)/      //  //
    // wI = tokenWeightIn      tAo =   \      \                                             //   //
    // tW = totalWeight                    /     /      wO \       \                             //
    // sF = swapFee                    *  | 1 - |  1 - ---- | * sF  |                            //
    // eF = exitFee                        \     \      tW /       /                             //
    **********************************************************************************************/
    function calcSingleOutGivenPoolIn(
        uint tokenBalanceOut,
        uint tokenWeightOut,
        uint poolSupply,
        uint totalWeight,
        uint poolAmountIn,
        uint swapFee
    )
    public pure
    returns (uint tokenAmountOut)
    {
        uint normalizedWeight = eDiv(tokenWeightOut, totalWeight);
        // charge exit fee on the pool token side
        // pAiAfterExitFee = pAi*(1-exitFee)
        uint poolAmountInAfterExitFee = eMul(poolAmountIn, eSub(EONE, EXIT_FEE));
        uint newPoolSupply = eSub(poolSupply, poolAmountInAfterExitFee);
        uint poolRatio = eDiv(newPoolSupply, poolSupply);

        // newBalTo = poolRatio^(1/weightTo) * balTo;
        uint tokenOutRatio = ePow(poolRatio, eDiv(EONE, normalizedWeight));
        uint newTokenBalanceOut = eMul(tokenOutRatio, tokenBalanceOut);

        uint tokenAmountOutBeforeSwapFee = eSub(tokenBalanceOut, newTokenBalanceOut);

        // charge swap fee on the output token side
        //uint tAo = tAoBeforeSwapFee * (1 - (1-weightTo) * swapFee)
        uint zaz = eMul(eSub(EONE, normalizedWeight), swapFee);
        tokenAmountOut = eMul(tokenAmountOutBeforeSwapFee, eSub(EONE, zaz));
        return tokenAmountOut;
    }

    /**********************************************************************************************
    // calcPoolInGivenSingleOut                                                                  //
    // pAi = poolAmountIn               // /               tAo             \\     / wO \     \   //
    // bO = tokenBalanceOut            // | bO - -------------------------- |\   | ---- |     \  //
    // tAo = tokenAmountOut      pS - ||   \     1 - ((1 - (tO / tW)) * sF)/  | ^ \ tW /  * pS | //
    // ps = poolSupply                 \\ -----------------------------------/                /  //
    // wO = tokenWeightOut  pAi =       \\               bO                 /                /   //
    // tW = totalWeight           -------------------------------------------------------------  //
    // sF = swapFee                                        ( 1 - eF )                            //
    // eF = exitFee                                                                              //
    **********************************************************************************************/
    function calcPoolInGivenSingleOut(
        uint tokenBalanceOut,
        uint tokenWeightOut,
        uint poolSupply,
        uint totalWeight,
        uint tokenAmountOut,
        uint swapFee
    )
    public pure
    returns (uint poolAmountIn)
    {

        // charge swap fee on the output token side
        uint normalizedWeight = eDiv(tokenWeightOut, totalWeight);
        //uint tAoBeforeSwapFee = tAo / (1 - (1-weightTo) * swapFee) ;
        uint zoo = eSub(EONE, normalizedWeight);
        uint zar = eMul(zoo, swapFee);
        uint tokenAmountOutBeforeSwapFee = eDiv(tokenAmountOut, eSub(EONE, zar));

        uint newTokenBalanceOut = eSub(tokenBalanceOut, tokenAmountOutBeforeSwapFee);
        uint tokenOutRatio = eDiv(newTokenBalanceOut, tokenBalanceOut);

        //uint newPoolSupply = (ratioTo ^ weightTo) * poolSupply;
        uint poolRatio = ePow(tokenOutRatio, normalizedWeight);
        uint newPoolSupply = eMul(poolRatio, poolSupply);
        uint poolAmountInAfterExitFee = eSub(poolSupply, newPoolSupply);

        // charge exit fee on the pool token side
        // pAi = pAiAfterExitFee/(1-exitFee)
        poolAmountIn = eDiv(poolAmountInAfterExitFee, eSub(EONE, EXIT_FEE));
        return poolAmountIn;
    }
}
