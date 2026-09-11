# Regression tests

Run the suite from anywhere in the repository:

```bash
./tests/test.sh
```

The tests require Bash and ImageMagick, just like the main script. They create
small solid-color PNG fixtures in a temporary directory and remove them when
the run finishes. No fixture images or output files are stored in the
repository.

The suite checks montage, crop, resize, each, zip, pagination,
output-exclusion, argument-validation, and font-discovery behavior. Pagination
coverage includes PDF and PNG output, paper dimensions, margins, overlap,
headers, footers, creation timestamps, preprocessing order, automatic output
directories, parent-directory selection, atomic replacement, invalid input,
dependency isolation, complete margin edges, zero-overlap row continuity,
timestamp-source priority, large page-number width, and every incompatible
pagination option. Assertions use
dimensions, selected pixels, filenames, file counts, exit statuses, and error
messages rather than encoded image hashes, so minor differences between
ImageMagick versions do not cause false failures.
