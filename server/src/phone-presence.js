// Whether the phone app is in the foreground. Defaults to foreground so a
// client that never reports presence is not notified for every answer.
let foreground = true;

export function setPhoneForeground(value) {
  foreground = Boolean(value);
}

export function phoneInForeground() {
  return foreground;
}

export function resetPhonePresence() {
  foreground = true;
}
