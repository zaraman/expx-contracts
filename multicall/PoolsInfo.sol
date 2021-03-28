// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.5.0;

interface PoolInterface {
    function getBalance(address) external view returns (uint256);
}

contract PoolsInfo {

    function getPoolsBalances(address[][] memory pools, uint256 length) public view
    returns (uint256 blockNumber, uint256[] memory returnData) {
        uint256 position = 0;

        blockNumber = block.number;
        returnData = new uint256[](length);

        for (uint256 i = 0; i < pools.length; i++) {
            PoolInterface pool = PoolInterface(pools[i][0]);

            for (uint256 j = 1; j < pools[i].length; j++) {
                returnData[position] = pool.getBalance(pools[i][j]);
                position = position + 1;
            }
        }
    }
}