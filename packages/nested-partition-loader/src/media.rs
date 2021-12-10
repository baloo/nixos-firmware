use aligned::Aligned;
use bootsector::{
    list_partitions,
    read::{Read, ReaderError, Seek, SeekFrom},
    Error,
};
use core::{convert::TryFrom, ops::Deref};
use nom::{
    branch::alt,
    bytes::complete::{tag, take_while1},
    character::{complete::space1, is_hex_digit},
    combinator::{eof, map_res},
    multi::fold_many0,
    IResult,
};
use smallvec::SmallVec;
use uefi::{
    prelude::*,
    proto::{
        loaded_image::LoadedImage,
        media::{
            block::BlockIO,
            file::{File, FileAttribute, FileInfo, FileInfoHeader, FileMode, FileType},
            fs::SimpleFileSystem,
            partition::PartitionInfo,
        },
    },
    table::boot::MemoryType,
    {CString16, Guid},
};
use uuid::Uuid;

struct BlockReader<'a> {
    inner: &'a mut BlockIO,
    pos: u64,
    starting_lba: u64,
    ending_lba: u64,
    block_size: u32,
    media_id: u32,
}

impl<'a> BlockReader<'a> {
    fn new(inner: &'a mut BlockIO, starting_lba: u64, ending_lba: u64) -> Self {
        let media = inner.media();
        let media_id = media.media_id();
        let block_size = media.block_size();
        info!("block_size = {}", block_size);
        Self {
            inner,
            pos: 0,
            starting_lba,
            ending_lba,
            block_size,
            media_id,
        }
    }

    const fn max_pos(&self) -> u64 {
        (self.ending_lba - self.starting_lba) * (self.block_size as u64)
    }

    const fn lba(&self) -> (u64, usize) {
        let block_size = self.block_size as u64;
        (self.pos / block_size, (self.pos % block_size) as usize)
    }
}

impl<'a> ReaderError for BlockReader<'a> {
    type Error = ();
}

impl<'a> Read for BlockReader<'a> {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize, Error<Self::Error>> {
        todo!();
    }
    fn read_exact(&mut self, buf: &mut [u8]) -> Result<(), Error<Self::Error>> {
        let (lba, offset) = self.lba();
        if offset == 0 {
            info!("aligned pos={} lba={} len={}", self.pos, lba, buf.len());
            let out = self
                .inner
                .read_blocks(self.media_id, lba, buf)
                .map_err(|_| Error::Io(()));
            //info!("buf: {:x?}", buf);
            self.pos += buf.len() as u64;
            out
        } else {
            warn!("unaligned read");
            // Here we have an unaligned read, so we'll read in a scratch buffer and copy what we
            // need from it, then get a second read.
            let mut scratch = [0u8; 520];

            self.inner
                .read_blocks(self.media_id, lba, &mut scratch[..])
                .map_err(|_| Error::Io(()))?;
            buf.copy_from_slice(&scratch[offset..(self.block_size as usize)]);
            self.inner
                .read_blocks(
                    self.media_id,
                    lba + 1,
                    &mut buf[(self.block_size as usize - offset)..],
                )
                .map_err(|_| Error::Io(()))
        }
        .map(|_| ())
    }
}

impl<'a> Seek for BlockReader<'a> {
    fn seek(&mut self, pos: SeekFrom) -> Result<u64, Error<Self::Error>> {
        use SeekFrom::*;
        match pos {
            Current(relative) if relative < 0 => {
                let new = self.pos.checked_sub(relative as u64).ok_or(Error::Io(()))?;
                self.pos = new;
                Ok(self.pos)
            }
            Current(relative) => {
                let new = self.pos.checked_add(relative as u64).ok_or(Error::Io(()))?;
                if new > self.max_pos() {
                    return Err(Error::Io(()));
                }
                self.pos = new;
                Ok(self.pos)
            }
            End(relative) if relative > 0 => Err(Error::Io(())),
            End(relative) => {
                let new = self
                    .max_pos()
                    .checked_sub(relative as u64)
                    .ok_or(Error::Io(()))?;
                self.pos = new;
                Ok(self.pos)
            }
            Start(offset) if offset >= self.max_pos() => Err(Error::Io(())),
            Start(offset) => {
                self.pos = offset;
                Ok(self.pos)
            }
        }
    }
}

#[derive(Debug, Eq, PartialEq, Copy, Clone)]
enum Options {
    BootIndex(Uuid),
}

impl Options {
    fn parse_options(input: &str) -> Result<SmallVec<[Options; 16]>, ()> {
        fn parse_boot_index(input: &str) -> IResult<&str, Options> {
            let (rest, _) = tag("boot-index=")(input)?;
            let (rest, value) = map_res(
                take_while1(|c: char| {
                    ('0'..='9').contains(&c)
                        || ('a'..='f').contains(&c)
                        || ('A'..='F').contains(&c)
                        || c == '-'
                }),
                Uuid::parse_str,
            )(rest)?;

            Ok((rest, Options::BootIndex(value)))
        }

        let (_rest, out) = fold_many0(
            parse_boot_index,
            || SmallVec::new(),
            |mut acc, item| {
                acc.push(item);
                acc
            },
        )(input)
        .map_err(|_| ())?;

        Ok(out)
    }
}

pub fn test(image: Handle, bt: &BootServices) {
    let loaded_image = bt
        .handle_protocol::<LoadedImage>(image)
        .expect_success("Failed to open LoadedImage protocol");
    let loaded_image = unsafe { &*loaded_image.get() };

    let mut buf = [0u8; 128];
    let options = loaded_image
        .load_options(&mut buf)
        .expect("failed to load options");
    let options = Options::parse_options(options).expect("parse options");
    info!("loaded image options: {:?}", options);

    let firmware_uuid = if let Options::BootIndex(options) = options[0] {
        options
    } else {
        todo!();
    };
    let uuid = firmware_uuid.as_fields();
    let clock_seq_and_variant = u16::from_be_bytes([uuid.3[0], uuid.3[1]]);
    let node = u64::from_be_bytes([
        0, 0, uuid.3[2], uuid.3[3], uuid.3[4], uuid.3[5], uuid.3[6], uuid.3[7],
    ]);

    let target_guid = Guid::from_values(uuid.0, uuid.1, uuid.2, clock_seq_and_variant, node);
    info!("target: {:?}", target_guid);

    let handles = bt
        //.find_handles::<SimpleFileSystem>()
        .find_handles::<PartitionInfo>()
        .expect_success("Failed to get handles for `SimpleFileSystem` protocol");
    for handle in handles {
        //let fs = bt
        //    .handle_protocol::<SimpleFileSystem>(handle)
        //    .expect_success("Failed to get fs info");
        //let fs = unsafe { &mut *fs.get() };

        let pi = bt.handle_protocol::<PartitionInfo>(handle);
        pi.map_inner(|pi| {
            let pi = unsafe { &*pi.get() };

            let gpt = if let Some(mbr) = pi.mbr_partition_record() {
                info!("MBR partition: {:?}", mbr);
                return;
            } else if let Some(gpt) = pi.gpt_partition_entry() {
                info!("GPT partition: {:?}", gpt);
                if gpt.unique_partition_guid != target_guid {
                    info!("skipping");
                    return;
                } else {
                    info!("found target partition");
                }
                gpt
            } else {
                info!("Unknown partition");
                return;
            };

            let block_handle = bt
                .handle_protocol::<BlockIO>(handle)
                .expect_success("Failed to access io");

            info!("opened target partition");
            let block_handle = unsafe { &mut *block_handle.get() };

            let blocksize = block_handle.media().block_size();
            let mut block_reader = BlockReader::new(block_handle, gpt.starting_lba, gpt.ending_lba);

            let partitions = list_partitions(&mut block_reader, &Default::default())
                .expect("failed to read partitions");
            info!("partitions: {:x?}", partitions);

            // TODO: check the partition-guid == 5c513513-e1b6-4fb1-aee8-b12da81551f3
            let kernel_partition = &partitions[0];

            block_reader.seek(SeekFrom::Start(kernel_partition.first_byte));
            let mut buf: SmallVec<[u8; 4096]> = smallvec::smallvec![0u8; 4096];
            block_reader.read_exact(&mut buf);

            let mut kernel_size = [0u8; 4];
            kernel_size.copy_from_slice(&buf[..4]);
            let kernel_size = u32::from_le_bytes(kernel_size);
            let kernel_size_aligned = kernel_size.aligned(4096) as usize;
            info!("kernel_size {}", kernel_size);

            assert!(
                (kernel_size_aligned as u64) < kernel_partition.len,
                "kernel_size can't be longer than the partition that stores it"
            );

            //let mut directory = fs.open_volume().unwrap().unwrap();
            //let linux_kernel = directory.open("linux.efi", FileMode::Read, FileAttribute::READ_ONLY)
            //    .expect_success("able to open the kernel");

            //let mut linux_kernel = match linux_kernel.into_type().expect_success("unexpected file type") {
            //    FileType::Regular(f) => f,
            //    _ => panic!("unexpected directory when opening kernel"),
            //};

            //let mut buf = [0u8; core::mem::size_of::<FileInfoHeader>() + 32 /* file name is less than 16 bytes (utf16) */];
            //let info = linux_kernel
            //    .get_info::<FileInfo>(&mut buf)
            //    .expect_success("unable to get kernel size");
            //let size = info.file_size() as usize;

            let buf = bt
                .allocate_pool(MemoryType::LOADER_DATA, kernel_size_aligned)
                .expect_success("unable to allocate memory");
            let buf: &mut [u8] =
                unsafe { core::slice::from_raw_parts_mut(buf, kernel_size_aligned) };
            info!("kernel memory allocated");

            block_reader.read_exact(&mut buf[..]);
            let buf = &buf[..(kernel_size as usize)];

            //let read = linux_kernel
            //    .read(buf)
            //    .expect_success("unable to read kernel");

            //assert!(read == size);
            info!("kernel loaded");

            let linux_handle = bt
                .load_image_from_buffer(image, &buf)
                .expect_success("load linux kernel");

            let linux_image = bt
                .handle_protocol::<LoadedImage>(linux_handle)
                .expect_success("lookup linux image");
            let linux_image = unsafe { &mut *linux_image.get() };

            let options = format!("console=ttyS0 panic=1 firmware.loaded={}", firmware_uuid);

            let options = CString16::try_from(options.as_str()).unwrap();
            let options = options.deref();

            unsafe { linux_image.set_load_options(options.as_ptr(), options.num_bytes() as u32) };

            bt.start_image(linux_handle)
                .expect_success("start linux kernel");
            info!("returned?");
        });
    }
}
