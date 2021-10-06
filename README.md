# Implementing Copy Offloading in the Linux Kernel

## Introduction

Efforts to add copy offloading support in the Linux kernel started considerable
time ago. Despite this copy offloading support is not yet upstream and there is
no detailed plan yet of how to implement copy offloading.

This document outlines a possible implementation. The purpose of this document
is to help guiding the conversations around copy offloading.

## Block Layer

We need an interface to pass copy offload requests from user space or file
systems to block drivers. Although the first implementation of copy offloading
added a single operation to the block layer for copy offloading, there seems
to be agreement today to implement copy offloading as two operations,
namely `REQ_COPY_IN` and `REQ_COPY_OUT`.

A possible approach is as follows:

* Fall back to a non-offloaded copy operation if necessary, e.g. if copy
  offloading is not supported or if data is encrypted and the ciphertext
  depends on the LBA. The following code may be a good starting point:
  `drivers/md/dm-kcopyd.c`.
* If the block driver supports copy offloading, submit the `REQ_COPY_IN`
  operation first. The block driver stores the data ranges associated with the
  `REQ_COPY_IN` operation.
* Wait for completion of the `REQ_COPY_IN` operation.
* After the `REQ_COPY_IN` operation has completed, submit the `REQ_COPY_OUT`
  operation and include a reference to the `REQ_COPY_IN` operation. If the
  block driver that receives the `REQ_COPY_OUT` operation receives a matching
  `REQ_COPY_IN` operation, offload the copy operation. Otherwise report that no
  data has been copied and let the block layer perform a non-offloaded copy
  operation.

The operation type is stored in the top bits of the `bi_opf` member of struct
bio.  With each bio a single data buffer and a single contiguous byte range on
the storage medium are associated. Pointers to the data buffer occur in
`bi_io_vec[]`. The affected byte range is represented by `bi_iter.bi_sector` and
`bi_iter.bi_size`.

While the NVMe and SCSI copy offload commands both support multiple source
ranges, XCOPY supports multiple destination ranges while the NVMe simple copy
command supports a single destination range.

Possible approaches for passing the data ranges involved in a copy operation
from the block layer to block drivers are as follows:

* Attach a bio to each copy offload request and encode all relevant copy
  offload parameters in that data buffer. These parameters include source
  device and source ranges for `REQ_COPY_IN` and destination device and
  destination ranges for `REQ_COPY_OUT`. Let the block drivers translate these
  parameters into something the storage device understands (NVMe simple copy
  parameters or SCSI XCOPY parameters). Fill in the parameter structure size
  in `bi_iter.bi_size`. Set `bi_vcnt` to 1 and fill in `bio->bi_io_vec[0]`.
* Map each source range and each destination range onto a different bio. Link
  all the bios with the `bi_next` pointer and attach these bios to the copy
  offload requests. Leave `bi_vcnt` zero. This is related but not identical to
  the approach followed by `__blkdev_issue_discard()`.

I think that the first approach would require more changes in the device mapper
than the second approach since the device mapper code knows how to split bios
but not how to split a buffer with LBA range descriptors.

The following code needs to be modified no matter how copy offloading is
implemented:

* Request cloning. The code for checking the limits before request are cloned
  compares `blk_rq_sectors()` with `max_sectors`. This is inappropriate for
  `REQ_COPY_*` requests.
* Request splitting. `bio_split()` assumes that `bi_iter.bi_size` represents
  the number of bytes affected on the medium.
* Code related to retrying the original requests of a merged request with
  mixed failfast attributes, e.g. `blk_rq_err_bytes()`.
* Code related to partially completing a request, e.g. `blk_update_request()`.
* The code for merging block layer requests.
* `blk_mq_end_request()` since it calls `blk_update_request()` and
  `blk_rq_bytes()`.
* The plugging code because of the following test in the plugging code:
  `blk_rq_bytes(last) >= BLK_PLUG_FLUSH_SIZE`.
* The I/O accounting code (task_io_account_read()) since that code uses
  bio_has_data() and hence skips discard, secure erase and write zeroes
  requests:
```
static inline bool bio_has_data(struct bio *bio)
{
	return bio && bio->bi_iter.bi_size &&
	    bio_op(bio) != REQ_OP_DISCARD &&
	    bio_op(bio) != REQ_OP_SECURE_ERASE &&
	    bio_op(bio) != REQ_OP_WRITE_ZEROESy;
}
```

Block drivers will need to use the `special_vec` member of struct request to
pass the copy offload parameters to the storage device. That member is used
e.g. when a REQ_OP_DISCARD operation is submitted to an NVMe driver. The SCSI
sd driver uses `special_vec` while processing an UNMAP or WRITE SAME command.

## Device Mapper

The device mapper may have to split a request. As an example, LVM is
based on the dm-linear driver. A request that is submitted to an LVM volume
has to be split if it affects multiple block devices. Copy offload requests
that affect multiple block devices should be split or should be onloaded.

The call chain for bio-based dm drivers is as follows:
```
dm_submit_bio(bio)
-> __split_and_process_bio(md, map, bio)
  -> __split_and_process_non_flush(clone_info)
    -> __clone_and_map_data_bio(clone_info, target_info, sector, len)
      -> clone_bio(dm_target_io, bio, sector, len)
      -> __map_bio(dm_target_io)
        -> ti->type->map(dm_target_io, clone)
```

## NVMe

Process copy offload commands by translating REQ_COPY_OUT requests into simple
copy commands.

## SCSI

From inside `sd_revalidate_disk()`, query the third-party copy VPD page. Extract
the following parameters (see also SPC-6):

* MAXIMUM CSCD DESCRIPTOR COUNT
* MAXIMUM SEGMENT DESCRIPTOR COUNT
* MAXIMUM DESCRIPTOR LIST LENGTH
* Supported third-party copy commands.
* SUPPORTED CSCD DESCRIPTOR ID (0 or more)
* ROD type descriptor (0 or more)
* TOTAL CONCURRENT COPIES
* MAXIMUM IDENTIFIED CONCURRENT COPIES
* MAXIMUM SEGMENT LENGTH

From inside `sd_init_command()`, translate REQ_COPY_OUT into either EXTENDED
COPY or POPULATE TOKEN + WRITE USING TOKEN.

Set the parameters in the copy offload commands as follows:

* We may have to set the STR bit. From SPC-6: "A sequential striped (STR) bit
  set to one specifies to the copy manager that the majority of the block
  device references in the parameter list represent sequential access of
  several block devices that are striped. This may be used by the copy manager
  to perform reads from a copy source block device at any time and in any
  order during processing of an EXTENDED COPY command as described in
  6.6.5.3. A STR bit set to zero specifies to the copy manager that disk
  references, if any, may not be sequential."
* Set the LIST ID USAGE field to 3 and the LIST ID to 0. This means that
  neither "held data" nor the RECEIVE COPY STATUS command are supported. This
  improves security because the data that is being copied cannot be accessed
  via the LIST ID.
* We may have to set the G_SENSE (good with sense data) bit. From SPC-6: " If
  the G _SENSE bit is set to one and the copy manager completes the EXTENDED
  COPY command with GOOD status, then the copy manager shall include sense
  data with the GOOD status in which the sense key is set to COMPLETED, the
  additional sense code is set to EXTENDED COPY INFORMATION AVAILABLE, and the
  COMMAND-SPECIFIC INFORMATION field is set to the number of segment
  descriptors the copy manager has processed."
* Clear the IMMED bit.

## System Call Interface

To submit copy offload requests from user space, we need:

* A system call for passing these requests, e.g. copy_file_range() or io_uring.
* Add a copy offload parameter format description to the user space ABI. The
  parameters include source device, source ranges, destination device and
  destination ranges.
* A flag that indicates whether or not it is acceptable to fall back to
  onloading the copy operation.

## Sysfs Interface

To do: define which aspects of copy offloading should be configurable through
new sysfs parameters under /sys/block/*/queue/.

## See Also

* Martin Petersen, [Copy
  Offload](https://www.mail-archive.com/linux-scsi@vger.kernel.org/msg28998.html),
  linux-scsi, 28 May 2014.
* Mikulas Patocka, [ANNOUNCE: SCSI XCOPY support for the kernel and device
  mapper](https://www.mail-archive.com/linux-kernel@vger.kernel.org/msg686111.html),
  15 July 2014.
* [kcopyd documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/kcopyd.html), kernel.org.
* Martin K. Petersen, [Copy Offload - Here Be Dragons](http://mkp.net/pubs/xcopy.pdf), 2019-08-21.
* Martin K. Petersen, [Re: [dm-devel] [RFC PATCH v2 1/2] block: add simple copy
support](https://lore.kernel.org/linux-nvme/yq1blf3smcl.fsf@ca-mkp.ca.oracle.com/), linux-nvme mailing list, 2020-12-08.
* NVM Express Organization, [NVMe - TP 4065b Simple Copy Command 2021.01.25 -
  Ratified.pdf](https://workspace.nvmexpress.org/apps/org/workgroup/allmembers/download.php/4773/NVMe%20-%20TP%204065b%20Simple%20Copy%20Command%202021.01.25%20-%20Ratified.pdf), 2021-01-25.
* Selvakumar S, [[RFC PATCH v5 0/4] add simple copy
  support](https://lore.kernel.org/linux-nvme/20210219124517.79359-1-selvakuma.s1@samsung.com/),
  linux-nvme, 2021-02-19.
* Mikulas Patocka, [Re: [PATCH 3/7] block: copy offload support infrastructure](https://lore.kernel.org/all/alpine.LRH.2.02.2108171630120.30363@file01.intranet.prod.int.rdu2.redhat.com/), linux-nvme, 2021-08-17.
