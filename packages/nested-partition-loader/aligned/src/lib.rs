#![no_std]

pub trait Aligned {
    fn aligned(&self, value: Self) -> Self;
}

macro_rules! aligned {
    ($t:ty) => {
        impl Aligned for $t {
            fn aligned(&self, value: Self) -> Self {
                let mask = value - 1;
                (self + mask) & !mask
            }
        }
    };
}

aligned!(u8);
aligned!(u16);
aligned!(u32);
aligned!(u64);
aligned!(usize);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() {
        assert_eq!(4093u32.aligned(4096), 4096);
        assert_eq!(4097u32.aligned(4096), 8192);
    }
}
