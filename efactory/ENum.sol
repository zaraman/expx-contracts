// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.5.12;

import "./EConst.sol";

contract ENum is EConst {

    function eToi(uint a)
    internal pure
    returns (uint)
    {
        return a / EONE;
    }

    function eFloor(uint a)
    internal pure
    returns (uint)
    {
        return eToi(a) * EONE;
    }

    function eAdd(uint a, uint b)
    internal pure
    returns (uint)
    {
        uint c = a + b;
        require(c >= a, "ERR_ADD_OVERFLOW");
        return c;
    }

    function eSub(uint a, uint b)
    internal pure
    returns (uint)
    {
        (uint c, bool flag) = eSubSign(a, b);
        require(!flag, "ERR_SUB_UNDERFLOW");
        return c;
    }

    function eSubSign(uint a, uint b)
    internal pure
    returns (uint, bool)
    {
        if (a >= b) {
            return (a - b, false);
        } else {
            return (b - a, true);
        }
    }

    function eMul(uint a, uint b)
    internal pure
    returns (uint)
    {
        uint c0 = a * b;
        require(a == 0 || c0 / a == b, "ERR_MUL_OVERFLOW");
        uint c1 = c0 + (EONE / 2);
        require(c1 >= c0, "ERR_MUL_OVERFLOW");
        uint c2 = c1 / EONE;
        return c2;
    }

    function eDiv(uint a, uint b)
    internal pure
    returns (uint)
    {
        require(b != 0, "ERR_DIV_ZERO");
        uint c0 = a * EONE;
        require(a == 0 || c0 / a == EONE, "ERR_DIV_INTERNAL"); // eMul overflow
        uint c1 = c0 + (b / 2);
        require(c1 >= c0, "ERR_DIV_INTERNAL"); //  eAdd require
        uint c2 = c1 / b;
        return c2;
    }

    function ePowi(uint a, uint n)
    internal pure
    returns (uint)
    {
        uint z = n % 2 != 0 ? a : EONE;

        for (n /= 2; n != 0; n /= 2) {
            a = eMul(a, a);

            if (n % 2 != 0) {
                z = eMul(z, a);
            }
        }
        return z;
    }

    // Compute b^(e.w) by splitting it into (b^e)*(b^0.w).
    // Use `ePowi` for `b^e` and `ePowK` for k iterations
    // of approximation of b^0.w
    function ePow(uint base, uint exp)
    internal pure
    returns (uint)
    {
        require(base >= MIN_EPOW_BASE, "ERR_EPOW_BASE_TOO_LOW");
        require(base <= MAX_EPOW_BASE, "ERR_EPOW_BASE_TOO_HIGH");

        uint whole  = eFloor(exp);
        uint remain = eSub(exp, whole);

        uint wholePow = ePowi(base, eToi(whole));

        if (remain == 0) {
            return wholePow;
        }

        uint partialResult = ePowApprox(base, remain, EPOW_PRECISION);
        return eMul(wholePow, partialResult);
    }

    function ePowApprox(uint base, uint exp, uint precision)
    internal pure
    returns (uint)
    {
        // term 0:
        uint a     = exp;
        (uint x, bool xneg)  = eSubSign(base, EONE);
        uint term = EONE;
        uint sum   = term;
        bool negative = false;


        // term(k) = numer / denom
        //         = (product(a - i - 1, i=1-->k) * x^k) / (k!)
        // each iteration, multiply previous term by (a-(k-1)) * x / k
        // continue until term is less than precision
        for (uint i = 1; term >= precision; i++) {
            uint bigK = i * EONE;
            (uint c, bool cneg) = eSubSign(a, eSub(bigK, EONE));
            term = eMul(term, eMul(c, x));
            term = eDiv(term, bigK);
            if (term == 0) break;

            if (xneg) negative = !negative;
            if (cneg) negative = !negative;
            if (negative) {
                sum = eSub(sum, term);
            } else {
                sum = eAdd(sum, term);
            }
        }

        return sum;
    }
}
