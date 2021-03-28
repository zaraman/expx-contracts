// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.5.12;

import "./EColor.sol";

contract EConst is EBronze {
    uint public constant EONE              = 10**18;

    uint public constant MIN_BOUND_TOKENS  = 2;
    uint public constant MAX_BOUND_TOKENS  = 8;

    uint public constant MIN_FEE           = EONE / 10**6;
    uint public constant MAX_FEE           = EONE / 10;
    uint public constant EXIT_FEE          = 0;

    uint public constant MIN_WEIGHT        = EONE;
    uint public constant MAX_WEIGHT        = EONE * 50;
    uint public constant MAX_TOTAL_WEIGHT  = EONE * 50;
    uint public constant MIN_BALANCE       = EONE / 10**12;

    uint public constant INIT_POOL_SUPPLY  = EONE * 100;

    uint public constant MIN_EPOW_BASE     = 1 wei;
    uint public constant MAX_EPOW_BASE     = (2 * EONE) - 1 wei;
    uint public constant EPOW_PRECISION    = EONE / 10**10;

    uint public constant MAX_IN_RATIO      = EONE / 2;
    uint public constant MAX_OUT_RATIO     = (EONE / 3) + 1 wei;
}
