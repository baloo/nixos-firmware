#![no_std]
#![no_main]
#![feature(asm)]
#![feature(abi_efiapi)]

#[macro_use]
extern crate log;
#[macro_use]
extern crate alloc;

use alloc::string::String;
use core::mem;
use uefi::prelude::*;
use uefi::table::boot::MemoryDescriptor;

#[entry]
fn efi_main(image: Handle, mut st: SystemTable<Boot>) -> Status {
    // Initialize utilities (logging, memory allocation...)
    uefi_services::init(&mut st).expect_success("Failed to initialize utilities");

    // unit tests here

    // output firmware-vendor (CStr16 to Rust string)
    let mut buf = String::new();
    st.firmware_vendor().as_str_in_buf(&mut buf).unwrap();
    info!("Firmware Vendor: {}", buf.as_str());

    // Reset the console before running all the other tests.
    st.stdout()
        .reset(false)
        .expect_success("Failed to reset stdout");

    // Ensure the tests are run on a version of UEFI we support.
    check_revision(st.uefi_revision());

    // Test all the boot services.
    let bt = st.boot_services();

    // Try retrieving a handle to the file system the image was booted from.
    bt.get_image_file_system(image)
        .expect("Failed to retrieve boot file system")
        .unwrap();

    shutdown(image, st);
}

fn check_revision(rev: uefi::table::Revision) {
    let (major, minor) = (rev.major(), rev.minor());

    info!("UEFI {}.{}", major, minor / 10);

    assert!(major >= 2, "Running on an old, unsupported version of UEFI");
    assert!(
        minor >= 30,
        "Old version of UEFI 2, some features might not be available."
    );
}


fn shutdown(image: uefi::Handle, mut st: SystemTable<Boot>) -> ! {
    use uefi::table::runtime::ResetType;

    // Get our text output back.
    st.stdout().reset(false).unwrap_success();

    // Exit boot services as a proof that it works :)
    let max_mmap_size =
        st.boot_services().memory_map_size() + 8 * mem::size_of::<MemoryDescriptor>();
    let mut mmap_storage = vec![0; max_mmap_size].into_boxed_slice();
    let (st, _iter) = st
        .exit_boot_services(image, &mut mmap_storage[..])
        .expect_success("Failed to exit boot services");

    // Shut down the system
    let rt = unsafe { st.runtime_services() };
    rt.reset(ResetType::Shutdown, Status::SUCCESS, None);
}
