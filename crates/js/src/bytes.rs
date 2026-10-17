//! The bytes of a `Uint8Array`, copied out of the engine.

use rquickjs::TypedArray;

/// A copy of the bytes of `array`. A detached buffer fails.
pub(crate) fn copy(array: &TypedArray<'_, u8>) -> rquickjs::Result<Vec<u8>> {
    #[expect(
        unsafe_code,
        reason = "rquickjs reads the bytes of a typed array only through an unsafe borrow"
    )]
    // SAFETY: the borrow ends inside this statement, and no JavaScript runs while it lives, so the engine cannot
    // detach or resize the buffer under it.
    let bytes = unsafe { array.as_bytes() }.map(<[u8]>::to_vec);
    bytes.ok_or_else(|| rquickjs::Error::new_from_js("detached Uint8Array", "bytes"))
}
