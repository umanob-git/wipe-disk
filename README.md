# wipe-disk — zero-fill a USB-docked HDD before disposal, read it all back, get a certificate

[日本語 README](README.ja.md)

Two PowerShell 5.1 scripts and a batch file that overwrite **every logical sector** of one magnetic HDD in a USB dock
with zeros, **read the whole disk back** and verify it is all zero, and write a **certificate of sanitization** per drive.

- Method: `diskpart clean all` (one pass of 0x00 over every logical sector). This is a *Clear* (overwrite) in the sense of
  NIST SP 800-88 Rev. 2 (Sept 2025, supersedes Rev. 1) §3.1.1. The standard states that an overwrite normally defeats even
  state-of-the-art laboratory recovery and does **not** call for multiple passes.
- Verification: after the overwrite the script opens `\\.\PhysicalDrive<N>` raw, reads it back (every sector by default,
  or 64 samples with `/quick`) and prints a machine verdict: `VERDICT: PASS / FAILED / UNKNOWN`.
- Certificate: one `logs\wipe-report-<serial>-<timestamp>.txt` (+ `.json`) per drive, following the certificate items in §4.6.
- **Not for SSDs.** A zero pass proves nothing on flash; the script refuses drives that report `MediaType = SSD`.
- **Dry run by default.** Nothing is written unless `-Apply` is given, and `-Apply` still asks you to type the model and
  the word `WIPE`. There is no undo.

## Guards (any one of these and nothing is written)

- the disk is the boot or system disk
- the disk is not on the USB bus (this tool is for a dock, so it never touches an internal disk)
- the disk reports `MediaType = SSD`
- the folder holding the script, `%TEMP%` or the system drive is on the target disk
- `-ExpectModel` is given and the model string does not contain it

## Usage (double-click)

`wipe-disk.cmd` walks you through it (prompts are in English):

1. UAC prompt → an elevated window opens
2. Disk list: `Number / Model / BusType / IsBoot / IsSystem / SizeGB`
3. `Disk number to wipe:` – type the number (Enter alone exits without doing anything)
4. The target's model, size and the partitions that will be destroyed are shown. If the guards pass, the drive's own serial
   number is read. Without `smartctl` (or if the dock does not pass ATA IDENTIFY through) you are asked to
   `Type the serial number printed on the drive label` (recorded as *manual*; Enter skips)
5. `Type the disk model exactly as shown above` – case and spaces are ignored
6. `Type WIPE (upper case) to start` → the overwrite begins
7. When it finishes, every sector is read back → `VERDICT` and `Result:`. `PASS` means the drive can go
8. The certificate is in `logs\wipe-report-<serial>-<timestamp>.txt`. Print it and fill in the hand-written fields

Nothing is written before step 6, so Ctrl+C or a wrong model at step 5 aborts safely.

Optional arguments:

```
wipe-disk.cmd 3                    start with disk 3 preselected
wipe-disk.cmd 3 ST500DM002         also require the model to contain ST500DM002
wipe-disk.cmd 3 "" /quick          sampled read-back (64 places) instead of every sector
wipe-disk.cmd 3 "" /dryrun         show what would happen, write nothing
wipe-disk.cmd 3 "" /verifyonly     read back only, write nothing
```

Time: a 500 GB HDD on USB 3 takes 1–2 h to overwrite (measured: 77 min at 107 MB/s) plus 1–2 h to read every
sector back. On USB 2 expect 4–5 h each. Do not touch the dock's power or cable while it runs.
If Windows offers to "initialize the disk" afterwards, cancel, power the dock off and remove the drive.

## Calling the script directly (elevated PowerShell)

```powershell
.\Wipe-Disk.ps1 -DiskNumber 3 -ExpectModel ST500DM002                 # dry run
.\Wipe-Disk.ps1 -DiskNumber 3 -ExpectModel ST500DM002 -Apply          # overwrite + sampled verify
.\Wipe-Disk.ps1 -DiskNumber 3 -ExpectModel ST500DM002 -Apply -FullVerify
.\Wipe-Disk.ps1 -DiskNumber 3 -VerifyOnly -FullVerify                 # read-back only
.\Wipe-Disk.ps1 -DiskNumber 3 -Apply -FullVerify -LabelSerial 5VM0XXXX -Operator "Taro Yamada"
.\Get-DriveIdentity.ps1 -DiskNumber 3                                 # just show how the serial would be obtained (read-only)
```

Exit codes: `0` PASS or dry run · `1` verify FAILED or diskpart failed · `2` a guard or a confirmation aborted (nothing
written) · `3` verify could not be performed (UNKNOWN).

## The certificate

Written after every `-Apply` / `-VerifyOnly` run as `logs\wipe-report-<serial>-<timestamp>.txt` (UTF-8 with BOM) plus a JSON
twin with the same fields. The wording lives in the template `report.ja.txt` (the `@key=value` header is the dictionary
for the variable phrases; the scripts themselves stay ASCII).

| Section | Contents |
|---|---|
| 1 Media | model · **serial and where it came from** · firmware · WWN · capacity / sector count / LBA range · connection (bridge serial) · partition table before the wipe. Asset tag and origin are hand-written fields |
| 2 Execution | Windows account · PC name / OS build · tool and version (Wipe-Disk.ps1, DiskPart, serial source) · log and JSON paths. Name / role / location / contact are hand-written |
| 3 Method | Clear (§3.1.1) / overwrite 0x00 × 1 (`diskpart clean all`) · start / end / duration · effective throughput · DiskPart exit code and output · state after the overwrite |
| 4 Verification | raw-device read-back method · scope (every sector or sampled) · bytes read and seconds · non-zero bytes found · result |
| 5 Verdict | PASS / FAILED / UNKNOWN with the verdict text |
| 6 Basis and scope | the standard's clauses (§3.1.1, §4.5.1, §4.6) and what was covered (magnetic HDD, every logical sector visible to the OS) |
| 7–8 | disposal checkboxes and signature lines for operator and verifier |

**Where the serial number comes from** (always stated on the certificate):

1. `smartctl` (smartmontools), if present, reads the drive's ATA IDENTIFY through the USB dock → matches the label.
   Install with `winget install smartmontools.smartmontools` in an elevated PowerShell, or drop `smartctl.exe` into `bin\`.
2. Otherwise you type the label serial at run time (recorded as *manual*; `-LabelSerial` on the command line also works).
3. Otherwise Windows' value is used and recorded as the *bridge* serial (behind a USB dock that is the dock's serial, not the drive's).

The certificate deliberately does not claim "unrecoverable"; it records that the Clear procedure of the standard was
performed and what the read-back found.

> The certificate text is currently **Japanese only** (this was written for a Japanese workplace). The template is a plain
> text file, so an English `report.en.txt` is straightforward and planned; contributions welcome.

## Notes

- **The `SerialNumber` Windows reports for a USB-docked drive is the dock's bridge serial, not the drive's.** Another drive in
  the same dock shows the same value. Identify the drive by model and size, and re-check the disk number in the dry run each
  time — numbers change when drives are plugged in or out.
- `logs\wipe-disk<N>-<timestamp>.log` keeps the target, the destroyed partitions, DiskPart's output, timings and the
  verification result. Keep it with the certificate.
- One certificate per run. Splitting overwrite and verification into two runs produces a *verify-only* certificate, so run
  both in one go for the record you hand in.
- While running, the script holds the PC awake with `SetThreadExecutionState` (released when the process ends; power
  settings are not changed).

## Files

| File | Role |
|---|---|
| `wipe-disk.cmd` | Launcher: self-elevates → lists disks → asks for the number → `Wipe-Disk.ps1 -Apply -FullVerify`. ASCII only |
| `Wipe-Disk.ps1` | The tool. Windows PowerShell 5.1. ASCII only (safe under any ANSI code page) |
| `Get-DriveIdentity.ps1` | Reads the drive's own serial (smartctl, else Windows' value). Read-only. ASCII only |
| `report.ja.txt` | Certificate template (UTF-8). Change wording here only |
| `logs\` | Run logs and certificates (git-ignored) |
| `tests\verify-test.ps1` | Unit tests for the read-back verdict, keep-awake and certificate rendering, using plain files. No elevation needed, 25 checks |

## Requirements

Windows 10 / 11 with Windows PowerShell 5.1 (built in). Administrator rights (the launcher asks). A USB dock or enclosure.
Optional: smartmontools for the drive's own serial.

## Field record

- 2026-09-19: Seagate ST500DM002 (465.76 GB, USB 3 dock): `clean all` 4,652 s (107 MB/s), sampled read-back all zero, PASS.
- 2026-09-19: Hitachi HTS545016B9A300 (149.05 GB, 2.5"): `clean all` 3,242 s (47 MB/s), exit 0. The full read-back that followed
  hit a bug in the script (an operator-precedence mistake in a `-f` format argument) and reported UNKNOWN; fixed, then
  re-verified with `/verifyonly`. That bug is why UNKNOWN exists as a distinct verdict: the tool never reports PASS it did not measure.

## Maintenance notes (things that actually broke)

- Never put `(` or `)` inside an `echo` within an `if ( ... )` block in the `.cmd` — `)` closes the block and the following
  lines run unconditionally.
- Wrap divisions in parentheses inside `-f` arguments: `"{2}" -f $a, $b / 1GB, $c` binds `,` tighter than `/`, so `-f`
  receives two arguments and fails at run time.
- Hex literals like `0x80000000` become negative int32; write `[uint32]2147483648`.
- Sending IOCTL_ATA_PASS_THROUGH / SCSI ATA PASS-THROUGH via P/Invoke failed with Win32 error 5 even when elevated
  (internal SATA and USB alike). Rather than ship an unexplained failure, that path was removed and the serial is read
  through smartctl. If you want to retry, find the cause first.
- After changing the verdict logic, run `tests\verify-test.ps1` (`fails=0`), a dry run, and confirm that passing the
  system SSD's disk number is refused.

## License

MIT — see [LICENSE](LICENSE). Use at your own risk: this tool destroys data by design.
