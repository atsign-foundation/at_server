/// The form an atKey is stored under, and therefore the form every key
/// returned by a keystore enumeration is in.
///
/// A keystore does not store the bytes it is handed. It folds them first —
/// trims, lowercases, and strips spaces — so `' Foo'`, `'F o o'` and `'foo'`
/// all address ONE record. Anything above the keystore that builds a key, or
/// compares a value against a key an enumeration returned, has to fold the
/// same way or it is asking about a different string from the one on disk.
///
/// The failure that makes this worth naming is silent in both directions: a
/// non-canonical spelling RESOLVES, so a caller using one reads and writes the
/// right record, while every equality test above the store answers "different"
/// about it. A guard phrased as "is this the record we are acting on?" then
/// says no, and the act goes ahead unguarded.
///
/// This is the fold WITHOUT the utf7 encoding a Hive-backed store applies on
/// top of it, because that encoding is undone again on the way out: key
/// enumerations decode, so the strings a caller gets back are in exactly this
/// form.
///
/// Idempotent, which is what lets a caller apply it early and again later
/// without changing the answer: the trim runs first, so no space the strip
/// removes can uncover leading or trailing whitespace for a second trim to
/// find.
String canonicalAtKey(String key) =>
    key.trim().toLowerCase().replaceAll(' ', '');
