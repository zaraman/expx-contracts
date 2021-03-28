// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;

/**
 * @author EXPX
 * @title Put all the constants in one place
 */

library EXPXConstants {
    // State variables (must be constant in a library)

    // B "ONE" - all math is in the "realm" of 10 ** 18;
    // where numeric 1 = 10 ** 18
    uint public constant EONE = 10**18;
    uint public constant MIN_WEIGHT = EONE;
    uint public constant MAX_WEIGHT = EONE * 50;
    uint public constant MAX_TOTAL_WEIGHT = EONE * 50;
    uint public constant MIN_BALANCE = EONE / 10**6;
    uint public constant MAX_BALANCE = EONE * 10**12;
    uint public constant MIN_POOL_SUPPLY = EONE * 100;
    uint public constant MAX_POOL_SUPPLY = EONE * 10**9;
    uint public constant MIN_FEE = EONE / 10**6;
    uint public constant MAX_FEE = EONE / 10;
    // EXIT_FEE must always be zero, or ConfigurableRightsPool._pushUnderlying will fail
    uint public constant EXIT_FEE = 0;
    uint public constant MAX_IN_RATIO = EONE / 2;
    uint public constant MAX_OUT_RATIO = (EONE / 3) + 1 wei;
    // Must match EConst.MIN_BOUND_TOKENS and EConst.MAX_BOUND_TOKENS
    uint public constant MIN_ASSET_LIMIT = 2;
    uint public constant MAX_ASSET_LIMIT = 8;
    uint public constant MAX_UINT = uint(-1);
}