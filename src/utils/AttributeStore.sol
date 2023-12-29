// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

library AttributeStore {
    struct Data {
        mapping(bytes32 => uint256) store;
    }

    function getAttribute(Data storage self, bytes32 uuid, string memory attrName) internal view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(uuid, attrName));
        return self.store[key];
    }

    function setAttribute(Data storage self, bytes32 uuid, string memory attrName, uint256 attrVal) internal {
        bytes32 key = keccak256(abi.encodePacked(uuid, attrName));
        self.store[key] = attrVal;
    }
}
