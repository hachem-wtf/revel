# make           : build the ISO (default)
# make run       : build and boot it headless (serial on stdout)
# make kernel    : just compile the kernel ELF
# make clean     : remove build output (kernel, ISO, caches)
# make distclean : also remove Limine's built host tool

ZIG  ?= zig
QEMU ?= qemu-system-x86_64

KERNEL := zig-out/bin/revel
ISO    := revel.iso

.PHONY: all kernel iso run clean distclean

all: iso

kernel:
	$(ZIG) build

limine/limine:
	$(MAKE) -C limine

# WARNING: DO NOT FUCK W/ THE \ DELIMETERS THEY ARE MADE TO BE PRETTY
#          ON OUTPUT, NOT PRETTY IN CODE. IF YOU DONT LIKE IT, GO
#          SHOKE ON A TIT
iso: kernel limine/limine
	rm -rf iso_root
	mkdir -p iso_root/boot/limine iso_root/EFI/BOOT
	cp $(KERNEL) iso_root/boot/revel
	cp boot/limine.conf iso_root/boot/limine/
	cp limine/limine-bios.sys    \
   limine/limine-bios-cd.bin \
   limine/limine-uefi-cd.bin iso_root/boot/limine/
	cp limine/BOOTX64.EFI  \
   limine/BOOTIA32.EFI iso_root/EFI/BOOT/
	xorriso -as mkisofs -R -r -J                                 \
    -b boot/limine/limine-bios-cd.bin                        \
    -no-emul-boot -boot-load-size 4 -boot-info-table         \
    -hfsplus -apm-block-size 2048                            \
    --efi-boot boot/limine/limine-uefi-cd.bin                \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    iso_root -o $(ISO)
	./limine/limine bios-install $(ISO)

run: iso
	$(QEMU) -M q35 -m 256M -cdrom $(ISO) -boot d -no-reboot -no-shutdown

clean:
	rm -rf iso_root zig-out .zig-cache $(ISO)

distclean: clean
	rm -f limine/limine
