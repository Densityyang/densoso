# Pinned food import dependency

`opencc_python_reimplemented-0.1.7-py2.py3-none-any.whl` is vendored only for
the build-time Taiwan FDA seed importer. Its SHA-256 is pinned in
`requirements-food-import.txt`. The Taiwan import uses OpenCC's `t2s`
conversion configuration to add Simplified Chinese searchable aliases while
leaving the official Traditional Chinese source name and raw source record
unchanged. Converted aliases that collide with another record are omitted and
written to the Taiwan alias review report.

This wheel is not copied into the application resources or runtime. The package
and OpenCC dictionary data are distributed under Apache-2.0; the upstream
license and notice are included beside the wheel. The upstream project is
<https://github.com/yichen0831/opencc-python> and the package release is
<https://pypi.org/project/opencc-python-reimplemented/0.1.7/>.
