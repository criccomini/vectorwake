// The four windows every journey runs in.
//
// Emulated, not real hardware. That is a real limit and worth stating: this
// covers layout, orientation, touch and pixel ratio, which is where the
// functional bugs are, and it does not cover thermals, a real GPU, or Safari.
// A phone stays a manual spot check.
//
// The short desktop is not padding. Five stops over a key cost about three
// hundred points whatever the window is, and whether they still fit with the
// panel one of them opens is only answerable by making the window short.

export const PROFILES = [
  {
    name: 'desktop',
    viewport: { width: 1280, height: 800 },
    deviceScaleFactor: 1,
    hasTouch: false,
    input: 'keyboard'
  },
  {
    name: 'desktop-short',
    viewport: { width: 1280, height: 560 },
    deviceScaleFactor: 1,
    hasTouch: false,
    input: 'keyboard'
  },
  {
    name: 'phone-portrait',
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 3,
    hasTouch: true,
    isMobile: true,
    input: 'touch'
  },
  {
    name: 'phone-landscape',
    viewport: { width: 844, height: 390 },
    deviceScaleFactor: 3,
    hasTouch: true,
    isMobile: true,
    input: 'touch'
  }
]

export function profile (name) {
  const found = PROFILES.find(p => p.name === name)
  if (!found) {
    throw new Error(
      `no profile ${JSON.stringify(name)}; have ${PROFILES.map(p => p.name).join(', ')}`)
  }
  return found
}
