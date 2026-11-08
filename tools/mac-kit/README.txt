dnetc Apple-silicon test kit (M-series Mac, native macOS)
=========================================================
About 25 minutes. On a performance core and then an efficiency core:
  1. -test rc5-72 on three builds
  2. MIX NEON vs MIX NEON HYBRID (current, and a new instruction order),
     alternating, 3 rounds, with the clock measured around each run
  3. vmix microbenchmark, 1 round per core type

  tar xzf dnetc-mac-kit.tar.gz
  cd dnetc-mac-kit
  sh run.sh            (or: sh run.sh dnetc   to skip vmix)

If macOS refuses to run the programs ("cannot be opened because the
developer cannot be verified"), run:  xattr -dr com.apple.quarantine .
Keep the Mac on mains power and otherwise idle. Send back the
mac-<chip>-<date>.txt file it writes. Nothing is sent over the network;
no config or buffer files are created.
Development build (mix-82/dnetc-client-base, branch hyb-skew).
