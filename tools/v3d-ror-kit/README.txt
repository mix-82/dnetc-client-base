V3D ror test kit (test only)
============================

What it tests
  A small change to Mesa's driver for the Raspberry Pi 4 and 5 GPU (V3D): use
  the GPU's "ror" (rotate right) instruction for 32-bit rotates. Today Mesa
  builds each rotate from two shifts and an OR. The change is in v3d-ror.diff.

What is in here
  mesa-stock/libRusticlOpenCL.so.1   Mesa's OpenCL library, Raspberry Pi OS source, unchanged
  mesa-ror/libRusticlOpenCL.so.1     the same source plus v3d-ror.diff
  rotcheck, rotcheck.c               compares rotates done by the GPU with the CPU's
  run.sh                             runs everything and writes one results archive
  BUILD-INFO.txt, SHA256SUMS

How to run (64-bit Raspberry Pi OS based on Debian 13, Pi 4 or Pi 5)
  ./run.sh /path/to/dnetc

  dnetc is the OpenCL client binary used in the 22 Nov test
  (sha256 52d5eab4e54e823fbfdae23c438ed36208f2148ef0ca641b6922790fcc349e5f).
  Do not use sudo. Takes about 10 to 15 minutes. Keep the Pi otherwise idle.

What it changes on the system
  Nothing. The two libraries are loaded only by the commands run.sh starts
  (through the OCL_ICD_VENDORS environment variable). All output goes to a
  results-<host>-<date> directory and .tar.gz inside this directory.

What to send back
  The results-<host>-<date>.tar.gz file, unedited.
