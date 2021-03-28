// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.5.12;

// Builds new EPools, logging their addresses and providing `isEPool(address) -> (bool)`

import "./EPool.sol";

contract EFactory is EBronze {
    event LOG_NEW_POOL(
        address indexed caller,
        address indexed pool
    );

    event LOG_EXPX(
        address indexed caller,
        address indexed expx
    );

    mapping(address=>bool) private _isEPool;

    function isEPool(address b)
    external view returns (bool)
    {
        return _isEPool[b];
    }

    function newEPool()
    external
    returns (EPool)
    {
        EPool ePool = new EPool();
        _isEPool[address(ePool)] = true;
        emit LOG_NEW_POOL(msg.sender, address(ePool));
        ePool.setController(msg.sender);
        return ePool;
    }

    address private _expx;

    constructor() public {
        _expx = msg.sender;
    }

    function getEXPX()
    external view
    returns (address)
    {
        return _expx;
    }

    function setEXPX(address b)
    external
    {
        require(msg.sender == _expx, "ERR_NOT_EXPX");
        emit LOG_EXPX(msg.sender, b);
        _expx = b;
    }

    function collect(EPool pool)
    external
    {
        require(msg.sender == _expx, "ERR_NOT_EXPX");
        uint collected = IBEP20(pool).balanceOf(address(this));
        bool xfer = pool.transfer(_expx, collected);
        require(xfer, "ERR_BEP20_FAILED");
    }
}
