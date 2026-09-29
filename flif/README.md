# FLIF16 encoder/decoder in pure Pascal

A port of the reference FLIF implementation (Sneyers & Wuille) to
Free Pascal. The produced bitstream is **byte-identical** to the C++
reference for every case covered by the test suite below, and files produced by either
implementation decode identically in the other.

## Licence

Same as the original: the decoder side derives from Apache-2.0-licensed sources, the
encoder side from LGPLv3+ sources.
