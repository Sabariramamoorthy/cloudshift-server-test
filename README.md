CloudShift Hardware Certification — USB Operator Guide
======================================================

BEFORE YOU GO
  - Copy scripts\ and pull\ to the root of the USB (E:\)
  - Ensure scripts are LF line-endings (see note at bottom)
  - On your laptop: create E:\pull\<hostname>\ folders if you want them pre-made
    (optional; the collect script creates them)

ON EACH LINUX TARGET
  1. Insert the USB
  2. Find the device:      lsblk
     (look for the ~8-64 GB removable disk, e.g. sdb1)
  3. Mount:                sudo mkdir -p /mnt/stick
                           sudo mount /dev/sdb1 /mnt/stick
  4. Install:              sudo bash /mnt/stick/scripts/install.sh
  5. Run cert (~31 min):   sudo cloudshift-test
     - Do NOT interrupt. Let the machine finish.
  6. Copy reports back:    sudo cloudshift-collect
  7. Unmount:              sudo umount /mnt/stick
  8. Remove stick, next machine.

AFTER THE ROUND
  1. Plug stick into Windows laptop (E:\)
  2. Open E:\pull\<hostname>\<UTC-timestamp>\
  3. Check summary.txt for RESULT: PASS / PASS_WITH_WARNINGS / FAIL
  4. Archive or upload as needed

LINE ENDINGS (critical)
  If scripts fail with "bad interpreter" or "/usr/bin/env: bash^M",
  convert them on the Linux target:
      sudo sed -i 's/\r$//' /mnt/stick/scripts/* /mnt/stick/scripts/cloudshift-test
  Then re-verify:
      cd /mnt/stick/scripts && sha256sum -c cloudshift-test.sha256

SECURITY
  - Scripts contain NO credentials.
  - Reports contain hostname, serial, MAC, kernel logs — treat as internal.
  - Never put reporter.env, github.env, tokens, or presigned URLs on the stick.
  - If the stick is lost: reports are the leak, not credentials. Still, encrypt if possible.
