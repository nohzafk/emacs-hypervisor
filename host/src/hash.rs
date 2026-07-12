// FNV-1a-64 content hashing shared between the host binary (`mod hash;`)
// and build.rs (which splices this file via `include!` since build scripts
// cannot depend on the bin crate).  Keep this file free of inner attributes
// so it stays include!-safe.

pub const FNV1A64_OFFSET: u64 = 0xcbf29ce484222325;

pub fn fnv1a64_update(mut hash: u64, bytes: &[u8]) -> u64 {
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

pub fn fnv1a64_digest(bytes: &[u8]) -> String {
    format!("fnv1a64:{:016x}", fnv1a64_update(FNV1A64_OFFSET, bytes))
}
