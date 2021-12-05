From [https://lore.kernel.org/linux-block/CA+1E3rJ7BZ7LjQXXTdX+-0Edz=zT14mmPGMiVCzUgB33C60tbQ@mail.gmail.com/](https://lore.kernel.org/linux-block/CA+1E3rJ7BZ7LjQXXTdX+-0Edz=zT14mmPGMiVCzUgB33C60tbQ@mail.gmail.com/):
```
Updated one (points from Keith and Bart) -

Given the multitude of things accumulated on this topic, Martin
suggested to have a table/matrix.
Some of those should go in the initial patchset, and the remaining are
to be staged for subsequent work.
Here is the attempt to split the stuff into two buckets. Please change
if something needs to be changed below.

1. Driver
*********
Initial: NVMe Copy command (single NS), including support in nvme-target
Subsequent: Multi NS copy, XCopy/Token-based Copy

2. Block layer
**************
Initial:
- Block-generic copy (REQ_OP_COPY), with interface accommodating two block-devs
- Emulation, when offload is natively absent
- DM support (at least dm-linear)

Subsequent: Integrity and encryption support

3. User-interface
*****************
Initial: new ioctl or io_uring opcode

4. In-kernel user
******************
Initial: at least one user
- dm-kcopyd user (e.g. dm-clone), or FS requiring GC (F2FS/Btrfs)

Subsequent:
- copy_file_range
```
