// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

library DLL {

    uint256 constant private _NULL_NODE_ID = 0;

    struct Node {
        uint256 next;
        uint256 prev;
    }

    struct Data {
        mapping(uint256 => Node) dll;
    }

    function isEmpty(Data storage self) internal view returns (bool) {
        return getStart(self) == _NULL_NODE_ID;
    }

    function contains(Data storage self, uint256 curr) internal view returns (bool) {
        if (isEmpty(self) || curr == _NULL_NODE_ID) {
            return false;
        } 

        bool isSingleNode = (getStart(self) == curr) && (getEnd(self) == curr);
        bool isNullNode = (getNext(self, curr) == _NULL_NODE_ID) && (getPrev(self, curr) == _NULL_NODE_ID);

        return isSingleNode || !isNullNode;
    }

    function getNext(Data storage self, uint256 curr) internal view returns (uint256) {
        return self.dll[curr].next;
    }

    function getPrev(Data storage self, uint256 curr) internal view returns (uint256) {
        return self.dll[curr].prev;
    }

    function getStart(Data storage self) internal view returns (uint256) {
        return getNext(self, _NULL_NODE_ID);
    }

    function getEnd(Data storage self) internal view returns (uint256) {
        return getPrev(self, _NULL_NODE_ID);
    }

    function insert(Data storage self, uint256 _prev, uint256 curr, uint256 _next) internal {
        require(curr != _NULL_NODE_ID);

        remove(self, curr);

        require(_prev == _NULL_NODE_ID || contains(self, _prev));
        require(_next == _NULL_NODE_ID || contains(self, _next));

        require(getNext(self, _prev) == _next);
        require(getPrev(self, _next) == _prev);

        self.dll[curr].prev = _prev;
        self.dll[curr].next = _next;

        self.dll[_prev].next = curr;
        self.dll[_next].prev = curr;
    }

    function remove(Data storage self, uint256 curr) internal {
        if (!contains(self, curr)) {
            return;
        }

        uint256 next = getNext(self, curr);
        uint256 prev = getPrev(self, curr);

        self.dll[next].prev = prev;
        self.dll[prev].next = next;

        delete self.dll[curr];
    }
}
