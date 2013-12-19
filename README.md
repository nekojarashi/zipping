zipping
=======

This gem is for compressing files as a zip and outputting to a stream (or a stream-like interface object). The output to a stream proceeds little by little, as files are compressed.

Install:
---
`gem 'zipping'`

Usage is simple:
```ruby
    require 'zipping'

    Zipping.files_to_zip my_stream, '/path/to/file'
```
You can pass multiple files.
```ruby
    Zipping.files_to_zip my_stream2, ['/path/to/file', '/another/path']
```
If you pass a folder, zipping compresses all files in the folder.
```ruby
    Zipping.files_to_zip my_stream3, ['/path/to/folder', '/path/to/other/file']
```
For example, you have files below:
```ruby
    /text/foo.txt
    /text/bar/baz.txt
    /images/abc.png
```
and you run command:
```ruby
    file = File.open '/my.zip', 'wb'
    Zipping.files_to_zip file, ['/text', '/images/abc.png']
    file.close
```
Then, you get a zip file, and you find entries below in it.

    text/
    text/foo.txt
    text/bar/
    text/bar/baz.txt
    abc.png

To get binary data of zip instead of saving as a file, prepare an 'ASCII-8bit'-encoded empty String object.
```ruby
    zip_data = ''.force_encoding('ASCII-8bit')
    Zipping.files_to_zip zip_data, ['/text', '/images/abc.png']
```
Then, you get zip binary data in `zip_data`.

---

Copyright (c) 2013 nekojarashi.
