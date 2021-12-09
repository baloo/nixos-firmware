use anyhow::{anyhow, bail, Context, Result};
use bootsector::{list_partitions, Attributes, Options, ReadMBR};
use clap::{App, Arg};
use devicemapper::{
    Device, DmName, DmUuid, LinearDev, LinearDevTargetParams, LinearTargetParams, Sectors,
    TargetLine, DM,
};
use nix::sys::stat::fstat;
use std::{fs::File, os::unix::io::AsRawFd, path::PathBuf};
use uuid::Uuid;

fn device_lookup(device: &File) -> Result<Device> {
    let stat =
        fstat(device.as_raw_fd()).with_context(|| format!("Unable to lookup device stat"))?;
    Ok(Device::from_kdev_t(stat.st_rdev as u32))
}

fn main() -> Result<()> {
    let matches = App::new("partuuidx")
        .version("0.0.0")
        .about("Load subpartitions in device mapper")
        .arg(
            Arg::with_name("device")
                .short("d")
                .long("device")
                .value_name("DEVICE")
                .help("Device to read partition table from")
                .takes_value(true)
                .required(true),
        )
        .get_matches();

    let device_name = matches
        .value_of("device")
        .ok_or(anyhow!("Missing device argument"))?;
    let device_name = PathBuf::from(device_name);

    let device = File::open(&device_name)
        .with_context(|| format!("Failed to open device {:?}", device_name))?;
    let dm_device = device_lookup(&device)?;
    let partitions = list_partitions(
        device,
        &Options {
            mbr: ReadMBR::Never,
            ..Options::default()
        },
    )
    .with_context(|| format!("Unable to read a GPT partition on device {:?}", device_name))?;

    let dm = DM::new().with_context(|| format!("Unable to open device mapper control"))?;

    for partition in partitions.iter() {
        let ref id = partition.id;
        match partition.attributes {
            Attributes::MBR { .. } => bail!("unexpected partition type MBR: {:?}", partition),
            Attributes::GPT {
                partition_uuid: guid,
                ..
            } => {
                trait ToUuid {
                    fn to_uuid(self) -> Self;
                }

                impl ToUuid for [u8; 16] {
                    fn to_uuid(mut self) -> Self {
                        self[0..4].reverse();
                        self[4..6].reverse();
                        self[6..8].reverse();
                        self
                    }
                }

                let uuid = guid.to_uuid();
                let uuid = Uuid::from_bytes(uuid);
                let mut uuid_buf = Uuid::encode_buffer();
                let uuid = uuid.to_hyphenated().encode_lower(&mut uuid_buf);
                let uuid = DmUuid::new(uuid).with_context(|| {
                    format!("Unable to parse uuid from partition table: {}", uuid)
                })?;

                let name = device_name
                    .file_name()
                    .ok_or_else(|| anyhow!("Unreachable: empty device filename"))?;
                let name = name
                    .to_str()
                    .ok_or(anyhow!("invalid utf8 chars in filename"))?;
                let name = format!("{name}p{id}", name = name, id = id);
                let name =
                    DmName::new(&name).with_context(|| format!("invalid device name: {}", name))?;

                let part_spec = TargetLine {
                    //start: Sectors(partition.first_byte / 512),
                    start: Sectors(0),
                    length: Sectors(partition.len / 512),
                    params: LinearDevTargetParams::Linear(LinearTargetParams {
                        device: dm_device,
                        start_offset: Sectors(partition.first_byte / 512),
                    }),
                };

                LinearDev::setup(&dm, &name, Some(&uuid), vec![part_spec]).with_context(|| {
                    format!(
                        "Unable to create binding for partition({id}): {part:?}",
                        id = id,
                        part = partition
                    )
                })?;
            }
        }
    }

    Ok(())
}
