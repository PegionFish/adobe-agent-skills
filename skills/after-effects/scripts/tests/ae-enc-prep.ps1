# ae-enc-prep.ps1 - data files for ae-encoding-test.jsx (pure ASCII source;
# the hanzi below are written from code points so this file stays ASCII).
# Writes 0x4E3B 0x5408 0x6210 0x6D4B 0x8BD5 (5 hanzi) as UTF-8 without BOM,
# UTF-8 with BOM and GBK (cp936), plus a GBK CSV with a quoted multi-line
# field (2-hanzi headers, 3-hanzi cells, see the code points below).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tests\ae-enc-prep.ps1
#
# Then run ae-encoding-test.jsx with an args file pointing at the four paths
# (see ae-encoding-test.jsx header).
$t = [System.IO.Path]::GetTempPath()
$s = -join([char]0x4E3B, [char]0x5408, [char]0x6210, [char]0x6D4B, [char]0x8BD5)
$nl = [string][char]10

[System.IO.File]::WriteAllText($t + 'ae-enc-utf8plain.txt', $s, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($t + 'ae-enc-utf8bom.txt',   $s, (New-Object System.Text.UTF8Encoding($true)))
$gbk = [System.Text.Encoding]::GetEncoding(936)
[System.IO.File]::WriteAllText($t + 'ae-enc-gbk.txt', $s, $gbk)

$zh3 = -join([char]0x4E3B, [char]0x5408, [char]0x6210)
$l1  = -join([char]0x7B2C, [char]0x4E00, [char]0x884C)
$l2  = -join([char]0x7B2C, [char]0x4E8C, [char]0x884C)
$q   = [string][char]34
$head = (-join([char]0x540D, [char]0x79F0)) + ',' + (-join([char]0x5907, [char]0x6CE8))
$row  = $q + $zh3 + $q + ',' + $q + $l1 + $nl + $l2 + $q
[System.IO.File]::WriteAllText($t + 'ae-enc-test.csv', $head + $nl + $row + $nl, $gbk)

Write-Output ('data files written to ' + $t)
