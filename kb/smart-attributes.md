# SMART and NVMe health

`smartctl -a /dev/disk` is a read. It does not repair anything. If it says the device lacks SMART, say so. Do not invent counts.

The attribute **name printed by smartctl** is what you trust. ID numbers are conventional on many ATA drives and are not a standard. Seagate and others pack several counters into one raw value (Raw_Read_Error_Rate is a common example). Do not treat a huge raw number as "that many bad sectors" unless the attribute is one of the plain counters below.

## ATA counters that are usually plain

These are the fields that, on most drives, really are counters. VALUE is the normalized score (higher is healthier). THRESH is the failure cutoff. A raw value that is increasing matters more than a single snapshot.

| ID | Typical name | How to read it |
| --- | --- | --- |
| 5 | Reallocated_Sector_Ct | Spare sectors already used. Any growth means media is being retired. A climbing count is a failing drive. |
| 187 | Reported_Uncorrect | Errors the drive could not correct and reported to the host. |
| 188 | Command_Timeout | Commands that timed out. Can be media, power, or a controller. |
| 196 | Reallocated_Event_Count | How often reallocation happened. Compare with ID 5. |
| 197 | Current_Pending_Sector | Sectors waiting to be remapped. Nonzero means unread data is likely. Urgent. |
| 198 | Offline_Uncorrectable | Sectors confirmed unreadable offline. Treat like pending sectors. |
| 199 | UDMA_CRC_Error_Count | Interface CRC failures. Usually the cable, port, or adapter, not the platters or NAND. A stable count with 5, 197, and 198 at zero is not a media failure. |
| 194 | Temperature_Celsius | Or 190 Airflow_Temperature_Cel. Sustained high temperature shortens life. It is not, by itself, proof of bad sectors. |
| 9 | Power_On_Hours | Age. Vendor-specific raw layout happens here too. Prefer the hours smartctl prints. |

Overall-health `PASSED` does not override a rising pending or reallocated count. `FAILED` means stop using the disk for anything except a clone.

## NVMe health log

`smartctl -a` on an NVMe device prints the SMART/Health information log. Fields that decide the next step:

- **Critical Warning** bits, from the NVMe spec: bit 0 spare below threshold, bit 1 temperature, bit 2 reliability degraded, bit 3 media has gone read-only, bit 4 volatile-memory backup failed. Any bit set is a problem. Bit 2 or bit 3 means stop writing.
- **Available Spare** versus **Available Spare Threshold**. Spare at or below the threshold is the same idea as a worn remap pool.
- **Percentage Used**. The vendor's endurance estimate. 100 means the rated write life is used up. The drive can still read, and it can also die. Plan a copy.
- **Media and Data Integrity Errors** (media errors). Nonzero means the device saw unrecoverable data errors. Do not keep using it as the only copy.
- **Error Information Log Entries**. A growing log means the controller is recording faults.
- **Temperature** and **Warning Temperature Time**. Thermal throttling is not the same as media errors.

NVMe `Percentage Used: 0%` and `Media and Data Integrity Errors: 0` with no critical warning is a healthy report. Do not invent a failure from power-on hours alone.

## What to say

Quote the numbers that are in the diagnostic. If a counter was not collected, name the read-only command (`smartctl -a /dev/...`) instead of guessing. A CRC-only pattern (attribute 199, pending and reallocated still zero) is a cable or port check, not a format.
