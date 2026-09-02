# Regression tests

Run the suite from anywhere in the repository:

```bash
./tests/test.sh
```

The tests require Bash and ImageMagick, just like the main script. They create
small solid-color PNG fixtures in a temporary directory and remove them when
the run finishes. No fixture images or output files are stored in the
repository.

The suite checks montage, crop, resize, each, zip, output-exclusion, and
argument-validation behavior. Assertions use dimensions, filenames, file
counts, exit statuses, and error messages rather than encoded image hashes, so
minor differences between ImageMagick versions do not cause false failures.

Until `screenshots.sh` implements automatic font discovery, that regression is
reported as pending on machines where ImageMagick has no registered default
font. Other montage tests use a temporary wrapper with a discovered system
font, keeping them independent of the host's ImageMagick font registry.
