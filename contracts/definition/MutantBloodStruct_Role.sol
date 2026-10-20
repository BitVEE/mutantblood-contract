// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

struct Role {
    uint64 TokenID;
    address TokenOwner;
    uint32 Version;
    uint64 Characteristics;
    uint64 Birthday;
    bytes Attributes;
}
