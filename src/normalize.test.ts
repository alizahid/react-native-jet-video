import { autoplayModeFor, normalizeSource, sourceKey } from './normalize'

describe('normalizeSource', () => {
  it('wraps string sources', () => {
    expect(normalizeSource('https://example.com/a.mp4')).toEqual({
      uri: 'https://example.com/a.mp4',
    })
  })

  it('passes through object sources with headers', () => {
    expect(
      normalizeSource({
        uri: 'https://example.com/a.m3u8',
        headers: { Authorization: 'Bearer x' },
      })
    ).toEqual({
      uri: 'https://example.com/a.m3u8',
      headers: { Authorization: 'Bearer x' },
    })
  })

  it('passes through the cache opt-out', () => {
    expect(
      normalizeSource({ uri: 'https://example.com/a.mp4', cache: false })
    ).toEqual({ uri: 'https://example.com/a.mp4', cache: false })
  })
})

describe('sourceKey', () => {
  it('is stable for equivalent object sources', () => {
    expect(sourceKey({ uri: 'a', headers: { h: '1' } })).toBe(
      sourceKey({ uri: 'a', headers: { h: '1' } })
    )
  })

  it('differs when the uri changes', () => {
    expect(sourceKey({ uri: 'a' })).not.toBe(sourceKey({ uri: 'b' }))
  })

  it('treats string and equivalent object identically enough for memo keys', () => {
    expect(sourceKey('a')).toBe('a')
  })
})

describe('autoplayModeFor', () => {
  it('maps undefined and false to off', () => {
    expect(autoplayModeFor(undefined)).toBe('off')
    expect(autoplayModeFor(false)).toBe('off')
  })

  it('maps true to always', () => {
    expect(autoplayModeFor(true)).toBe('always')
  })

  it('passes whenVisible through', () => {
    expect(autoplayModeFor('whenVisible')).toBe('whenVisible')
  })
})
