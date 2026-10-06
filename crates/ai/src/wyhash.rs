//! A streaming Wyhash as a [`Hasher`]. The encoder hashes each block per request, and Wyhash is several times faster
//! than the `SipHash` of [`std::hash::DefaultHasher`].

use std::hash::Hasher;

const SECRET: [u64; 4] = [
    0xa076_1d64_78bd_642f,
    0xe703_7ed1_a0b4_28db,
    0x8ebc_6af0_9c88_c6e3,
    0x5899_65cc_7537_4cc3,
];

/// A streaming Wyhash state.
#[derive(Debug, Clone)]
pub(crate) struct Wyhash {
    state: [u64; 3],
    total_len: usize,
    buf: [u8; 48],
    buf_len: usize,
}

impl Wyhash {
    pub(crate) fn new(seed: u64) -> Self {
        let first = seed ^ mix(seed ^ SECRET[0], SECRET[1]);
        Wyhash {
            state: [first; 3],
            total_len: 0,
            buf: [0; 48],
            buf_len: 0,
        }
    }

    fn round(&mut self, input: &[u8; 48]) {
        for i in 0..3 {
            let a = read8(&input[16 * i..]);
            let b = read8(&input[16 * i + 8..]);
            self.state[i] = mix(a ^ SECRET[i + 1], b ^ self.state[i]);
        }
    }
}

impl Default for Wyhash {
    fn default() -> Self {
        Wyhash::new(0)
    }
}

impl Hasher for Wyhash {
    /// Add `input`. The last full 48-byte block stays in the buffer, because the final step reads it.
    fn write(&mut self, input: &[u8]) {
        self.total_len += input.len();
        if input.len() <= 48 - self.buf_len {
            self.buf[self.buf_len..self.buf_len + input.len()].copy_from_slice(input);
            self.buf_len += input.len();
            return;
        }
        let mut i = 0;
        if self.buf_len > 0 {
            i = 48 - self.buf_len;
            self.buf[self.buf_len..].copy_from_slice(&input[..i]);
            let block = self.buf;
            self.round(&block);
            self.buf_len = 0;
        }
        while i + 48 < input.len() {
            let mut block = [0; 48];
            block.copy_from_slice(&input[i..i + 48]);
            self.round(&block);
            i += 48;
        }
        let rest = &input[i..];
        if rest.len() < 16 && i >= 48 {
            let missing = 16 - rest.len();
            self.buf[48 - missing..].copy_from_slice(&input[i - missing..i]);
        }
        self.buf[..rest.len()].copy_from_slice(rest);
        self.buf_len = rest.len();
    }

    fn finish(&self) -> u64 {
        let mut state = self.state;
        let (a, b) = if self.total_len <= 16 {
            small_key(&self.buf[..self.buf_len])
        } else {
            // A short buffer reads the bytes before it, which the last full block left at the end of the buffer.
            let mut scratch = [0u8; 16];
            let (input, start): (&[u8], usize) = if self.buf_len < 16 {
                let missing = 16 - self.buf_len;
                scratch[..missing].copy_from_slice(&self.buf[48 - missing..]);
                scratch[missing..].copy_from_slice(&self.buf[..self.buf_len]);
                (&scratch, missing)
            } else {
                (&self.buf[..self.buf_len], 0)
            };
            state[0] ^= state[1] ^ state[2];
            let body = &input[start..];
            let mut i = 0;
            while i + 16 < body.len() {
                state[0] = mix(read8(&body[i..]) ^ SECRET[1], read8(&body[i + 8..]) ^ state[0]);
                i += 16;
            }
            (read8(&input[input.len() - 16..]), read8(&input[input.len() - 8..]))
        };
        let (a, b) = mum(a ^ SECRET[1], b ^ state[0]);
        mix(a ^ SECRET[0] ^ self.total_len as u64, b ^ SECRET[1])
    }
}

fn small_key(input: &[u8]) -> (u64, u64) {
    let len = input.len();
    if len >= 4 {
        let end = len - 4;
        let quarter = (len >> 3) << 2;
        (
            read4(input) << 32 | read4(&input[quarter..]),
            read4(&input[end..]) << 32 | read4(&input[end - quarter..]),
        )
    } else if len > 0 {
        (
            u64::from(input[0]) << 16 | u64::from(input[len >> 1]) << 8 | u64::from(input[len - 1]),
            0,
        )
    } else {
        (0, 0)
    }
}

fn read8(bytes: &[u8]) -> u64 {
    let mut word = [0; 8];
    word.copy_from_slice(&bytes[..8]);
    u64::from_le_bytes(word)
}

fn read4(bytes: &[u8]) -> u64 {
    let mut word = [0; 4];
    word.copy_from_slice(&bytes[..4]);
    u64::from(u32::from_le_bytes(word))
}

#[expect(clippy::cast_possible_truncation, reason = "the halves of a 128-bit product")]
fn mum(a: u64, b: u64) -> (u64, u64) {
    let product = u128::from(a) * u128::from(b);
    (product as u64, (product >> 64) as u64)
}

fn mix(a: u64, b: u64) -> u64 {
    let (low, high) = mum(a, b);
    low ^ high
}

#[cfg(test)]
mod tests {
    use super::*;

    // The vectors of the Wyhash reference test_vector.cpp.
    const VECTORS: [(u64, u64, &str); 7] = [
        (0, 0x0409_638e_e2bd_e459, ""),
        (1, 0xa841_2d09_1b5f_e0a9, "a"),
        (2, 0x32dd_92e4_b291_5153, "abc"),
        (3, 0x8619_1240_89a3_a16b, "message digest"),
        (4, 0x7a43_afb6_1d7f_5f40, "abcdefghijklmnopqrstuvwxyz"),
        (
            5,
            0xff42_329b_90e5_0d58,
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
        ),
        (
            6,
            0xc39c_ab13_b115_aad3,
            "12345678901234567890123456789012345678901234567890123456789012345678901234567890",
        ),
    ];

    #[test]
    fn split_input_hashes_like_one_write() {
        for (seed, expected, input) in VECTORS {
            let bytes = input.as_bytes();
            let mut whole = Wyhash::new(seed);
            whole.write(bytes);
            assert_eq!(whole.finish(), expected, "input {input:?}");
            for chunk in 1..=bytes.len().saturating_sub(1).max(1) {
                let mut hasher = Wyhash::new(seed);
                for piece in bytes.chunks(chunk) {
                    hasher.write(piece);
                }
                assert_eq!(hasher.finish(), expected, "input {input:?} in chunks of {chunk}");
            }
        }
        // Longer inputs cross several 48-byte blocks, and a final block that ends on the boundary.
        let long: Vec<u8> = (0..500u32).map(|i| u8::try_from(i % 251).unwrap()).collect();
        for len in [47, 48, 49, 96, 97, 144, 500] {
            let mut whole = Wyhash::new(9);
            whole.write(&long[..len]);
            for chunk in [1, 7, 16, 48, 50] {
                let mut split = Wyhash::new(9);
                for piece in long[..len].chunks(chunk) {
                    split.write(piece);
                }
                assert_eq!(split.finish(), whole.finish(), "len {len}, chunks of {chunk}");
            }
        }
    }
}
