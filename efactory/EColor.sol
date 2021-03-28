// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.5.12;

contract EColor {
    function getColor()
    external view
    returns (bytes32);
}

contract EBronze is EColor {
    function getColor()
    external view
    returns (bytes32) {
        return bytes32("BRONZE");
    }
}
