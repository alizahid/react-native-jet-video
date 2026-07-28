import { useCallback, useEffect, useState } from 'react'
import { Pressable, StyleSheet, Text, View } from 'react-native'
import { clearCache, getCacheSize, VideoView } from 'react-native-jet-video'

const SOURCE =
  'https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4'

export function Cache() {
  const [mounted, setMounted] = useState(true)
  const [size, setSize] = useState<number | null>(null)
  const [log, setLog] = useState('')

  const refreshSize = useCallback(async () => {
    setSize(await getCacheSize())
  }, [])

  useEffect(() => {
    const interval = setInterval(refreshSize, 1000)
    return () => clearInterval(interval)
  }, [refreshSize])

  return (
    <View style={styles.container}>
      {mounted ? (
        <VideoView
          source={SOURCE}
          autoplay
          muted
          loop
          style={styles.video}
          onPlaybackStateChange={(event) =>
            setLog(`state: ${event.status} (${event.reason})`)
          }
          onError={(event) => setLog(`error: ${event.code} ${event.message}`)}
        />
      ) : (
        <View style={[styles.video, styles.placeholder]}>
          <Text style={styles.placeholderText}>unmounted</Text>
        </View>
      )}

      <View style={styles.row}>
        <Pressable
          onPress={() => setMounted((value) => !value)}
          style={styles.button}
        >
          <Text style={styles.buttonText}>
            {mounted ? 'unmount' : 'remount (loads from cache)'}
          </Text>
        </Pressable>
        <Pressable
          onPress={async () => {
            await clearCache()
            await refreshSize()
            setLog('cache cleared')
          }}
          style={styles.button}
        >
          <Text style={styles.buttonText}>clear cache</Text>
        </Pressable>
      </View>

      <Text style={styles.info}>
        cache size:{' '}
        {size === null ? '—' : `${(size / (1024 * 1024)).toFixed(2)} MB`}
      </Text>
      <Text style={styles.info}>{log}</Text>
    </View>
  )
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    gap: 12,
    padding: 12,
  },
  video: {
    aspectRatio: 16 / 9,
    backgroundColor: '#000',
    width: '100%',
  },
  placeholder: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  placeholderText: {
    color: '#666',
  },
  row: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
  },
  button: {
    backgroundColor: '#5856d6',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 8,
  },
  buttonText: {
    color: '#fff',
    fontSize: 13,
  },
  info: {
    color: '#9f9',
    fontFamily: 'Menlo',
    fontSize: 12,
  },
})
