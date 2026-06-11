# Useful env vars

`vmArch` - `aarch64` or `x86_64`
`qemuDisplay` - `cocoa` or unset (or other valid options for `-display`)
`rockyVersion` - whatever point release
`anacondaInstallKind` - `cmdline` or `graphical` or `text` for substitution into kickstart file
`useOemDrv` - instead of rebuilding the ISO with the kickstart embedded, attach a volume labeled OEMDRV with it
