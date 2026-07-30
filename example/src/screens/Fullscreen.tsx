import { useRef, useState } from 'react'
import { Pressable, StyleSheet, Text, View } from 'react-native'
import { VideoView, type VideoViewRef } from 'react-native-jet-video'

const SOURCE =
  'https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4'

export function Fullscreen() {
  const chromeless = useRef<VideoViewRef>(null)
  const [isFullscreen, setIsFullscreen] = useState(false)
  const [log, setLog] = useState('')
  const [time, setTime] = useState(0)
  const [status, setStatus] = useState('idle')

  return (
    <View style={styles.container}>
      <Text style={styles.label}>
        controls={'{isFullscreen}'} + enterFullscreen()
      </Text>
      <VideoView
        ref={chromeless}
        source={SOURCE}
        autoplay
        muted
        loop
        controls={isFullscreen}
        style={styles.video}
        onFullscreenChange={setIsFullscreen}
        onPlaybackStateChange={(event) => setStatus(event.status)}
        onProgress={(event) => setTime(event.currentTime)}
        progressUpdateInterval={100}
      />
      <View style={styles.row}>
        <Pressable
          onPress={async () => {
            try {
              await chromeless.current?.enterFullscreen()
              setLog('enterFullscreen resolved')
            } catch (error) {
              setLog(`enterFullscreen rejected: ${String(error)}`)
            }
          }}
          style={styles.button}
        >
          <Text style={styles.buttonText}>enter fullscreen</Text>
        </Pressable>
      </View>

      <Text style={styles.label}>controls=true (system chrome)</Text>
      <VideoView
        source="https://media.w3.org/2010/05/sintel/trailer.mp4"
        muted
        loop
        controls
        style={styles.video}
      />

      <Text style={styles.info} testID="fullscreen-info">
        fullscreen: {String(isFullscreen)} · t={time.toFixed(2)} · {status}
        {log ? ` · ${log}` : ''}
      </Text>
    </View>
  )
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    gap: 8,
    padding: 12,
  },
  label: {
    color: '#999',
    fontSize: 13,
  },
  video: {
    aspectRatio: 16 / 9,
    backgroundColor: '#000',
    width: '100%',
  },
  row: {
    flexDirection: 'row',
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
