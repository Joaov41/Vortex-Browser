import React from 'react';
import {
  AbsoluteFill,
  Audio,
  Img,
  Sequence,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import {Video} from '@remotion/media';
import {TransitionSeries, linearTiming} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';
import {slide} from '@remotion/transitions/slide';
import {wipe} from '@remotion/transitions/wipe';

const palette = {
  ink: '#050507',
  white: '#f5f7fb',
  blue: '#7cc8ff',
  mint: '#77f6c2',
  silver: '#b8bec8',
};

const full: React.CSSProperties = {
  width: '100%',
  height: '100%',
};

const Background: React.FC<{light?: boolean; children: React.ReactNode}> = ({light, children}) => (
  <AbsoluteFill
    style={{
      background: light
        ? 'radial-gradient(circle at 62% 16%, #ffffff 0%, #eef3f8 55%, #dce4ec 100%)'
        : 'radial-gradient(circle at 64% 26%, #1b2735 0%, #080a0e 42%, #030304 78%)',
      color: light ? '#111216' : palette.white,
      fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Display", Inter, sans-serif',
      overflow: 'hidden',
    }}
  >
    {children}
  </AbsoluteFill>
);

const Eyebrow: React.FC<{children: React.ReactNode; dark?: boolean}> = ({children, dark}) => (
  <div
    style={{
      fontSize: 26,
      fontWeight: 650,
      letterSpacing: 5,
      color: dark ? '#4e5965' : palette.mint,
      textTransform: 'uppercase',
      marginBottom: 22,
    }}
  >
    {children}
  </div>
);

const Glow: React.FC<{x: number; y: number; color: string; size?: number}> = ({x, y, color, size = 520}) => {
  const frame = useCurrentFrame();
  const breath = 0.92 + Math.sin(frame / 22) * 0.08;
  return (
    <div
      style={{
        position: 'absolute',
        left: x,
        top: y,
        width: size,
        height: size,
        borderRadius: '50%',
        transform: `scale(${breath})`,
        background: color,
        filter: 'blur(130px)',
        opacity: 0.24,
      }}
    />
  );
};

const Device: React.FC<{
  src: string;
  width: number;
  radius: number;
  rotate?: number;
  delay?: number;
  shadow?: string;
}> = ({src, width, radius, rotate = 0, delay = 0, shadow = 'drop-shadow(0 34px 34px rgba(0,0,0,.46))'}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const enter = spring({fps, frame: frame - delay, config: {damping: 18, stiffness: 115}});
  return (
    <div
      style={{
        width,
        transform: `translateY(${interpolate(enter, [0, 1], [120, 0])}px) scale(${interpolate(enter, [0, 1], [.88, 1])}) rotate(${rotate}deg)`,
        opacity: enter,
      }}
    >
      <Img src={staticFile(src)} style={{width: '100%', display: 'block', borderRadius: radius, filter: shadow}} />
    </div>
  );
};

const Intro: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const word = spring({fps, frame: frame - 8, config: {damping: 18}});
  const line = interpolate(frame, [30, 60], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <Background>
      <Glow x={1060} y={110} color="#1978d3" size={680} />
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
        <div style={{textAlign: 'center', transform: `scale(${interpolate(word, [0, 1], [.82, 1])})`, opacity: word}}>
          <div style={{fontSize: 176, fontWeight: 720, letterSpacing: -10}}>Browser</div>
          <div style={{height: 5, width: 260 * line, margin: '22px auto 34px', borderRadius: 8, background: `linear-gradient(90deg, ${palette.blue}, ${palette.mint})`}} />
          <div style={{fontSize: 47, fontWeight: 470, color: '#c7ccd4', letterSpacing: -1}}>The web. Reimagined.</div>
        </div>
      </AbsoluteFill>
    </Background>
  );
};

const DeviceReveal: React.FC = () => {
  const frame = useCurrentFrame();
  const copy = interpolate(frame, [20, 48], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <Background light>
      <Glow x={920} y={280} color="#65d7ff" size={720} />
      <div style={{position: 'absolute', left: 126, top: 158, width: 680, opacity: copy, transform: `translateY(${(1 - copy) * 40}px)`}}>
        <Eyebrow dark>Meet Browser</Eyebrow>
        <div style={{fontSize: 100, lineHeight: .98, fontWeight: 740, letterSpacing: -6}}>One browser.<br />Every screen.</div>
        <div style={{fontSize: 31, lineHeight: 1.35, marginTop: 38, color: '#53606e', width: 560}}>A focused workspace for reading, researching, and getting things done.</div>
      </div>
      <div style={{position: 'absolute', right: 76, top: 128, display: 'flex', alignItems: 'center', gap: 30}}>
        <Device src="iphone-overview.png" width={300} radius={56} rotate={-4} delay={2} />
        <Device src="ipad-split-dark.png" width={700} radius={32} rotate={2} delay={12} />
      </div>
    </Background>
  );
};

const RecordingScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const enter = spring({fps, frame: frame - 5, config: {damping: 20}});
  const caption = interpolate(frame, [25, 55], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <Background>
      <Glow x={930} y={120} color="#1755a8" size={900} />
      <div style={{position: 'absolute', left: 112, top: 165, width: 520, zIndex: 3, opacity: caption}}>
        <Eyebrow>Live multitasking</Eyebrow>
        <div style={{fontSize: 92, lineHeight: 1, fontWeight: 720, letterSpacing: -5}}>Tabs that<br />move with you.</div>
        <div style={{fontSize: 31, lineHeight: 1.38, color: '#aeb7c4', marginTop: 34}}>Drag a tab. Choose a side. Keep your flow.</div>
      </div>
      <div
        style={{
          position: 'absolute',
          right: 80,
          top: 110,
          width: 1190,
          padding: 14,
          borderRadius: 58,
          background: 'linear-gradient(145deg,#bcc4d0,#22242a 22%,#050506 74%,#79818d)',
          boxShadow: '0 70px 160px rgba(0,0,0,.72), 0 0 0 1px rgba(255,255,255,.2)',
          transform: `translateY(${(1 - enter) * 90}px) scale(${interpolate(enter, [0, 1], [.92, 1])})`,
          opacity: enter,
        }}
      >
        <div style={{overflow: 'hidden', borderRadius: 44, aspectRatio: '2360 / 1640', background: '#000'}}>
          <Video src={staticFile('screen-recording.mp4')} muted objectFit="cover" style={full} />
        </div>
      </div>
    </Background>
  );
};

const MultitaskScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const title = spring({fps, frame: frame - 8, config: {damping: 18}});
  return (
    <Background light>
      <Glow x={650} y={220} color="#4ac2ff" size={700} />
      <AbsoluteFill style={{padding: '88px 110px'}}>
        <div style={{opacity: title, transform: `translateY(${(1 - title) * 35}px)`}}>
          <Eyebrow dark>Split. Drag. Continue.</Eyebrow>
          <div style={{fontSize: 84, fontWeight: 740, letterSpacing: -5}}>Multitasking, made fluid.</div>
        </div>
        <div style={{display: 'flex', gap: 44, alignItems: 'center', marginTop: 64}}>
        <Device src="ipad-split-light.png" width={875} radius={34} rotate={-2.2} delay={10} shadow="drop-shadow(0 28px 30px rgba(43,58,77,.26))" />
        <Device src="ipad-multitask.png" width={745} radius={32} rotate={2.8} delay={20} shadow="drop-shadow(0 28px 30px rgba(43,58,77,.26))" />
        </div>
      </AbsoluteFill>
    </Background>
  );
};

const AIScene: React.FC = () => {
  const frame = useCurrentFrame();
  const reveal = interpolate(frame, [14, 45], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <Background>
      <Glow x={1150} y={170} color="#5c36ce" size={680} />
      <Glow x={420} y={470} color="#167d70" size={580} />
      <div style={{position: 'absolute', left: 120, top: 170, width: 670, opacity: reveal, transform: `translateY(${(1 - reveal) * 35}px)`}}>
        <Eyebrow>AI Assistant</Eyebrow>
        <div style={{fontSize: 112, lineHeight: .98, fontWeight: 730, letterSpacing: -7}}>Ask<br />the page.</div>
        <div style={{fontSize: 34, lineHeight: 1.35, color: '#bbc2cf', marginTop: 38, width: 520}}>Summaries and answers, right where you work.</div>
      </div>
      <div style={{position: 'absolute', right: 120, top: 80, display: 'flex', gap: 34, alignItems: 'center'}}>
        <Device src="ipad-article-dark.png" width={760} radius={35} rotate={-2} delay={8} />
        <Device src="iphone-ai.png" width={370} radius={66} rotate={3} delay={18} />
      </div>
    </Background>
  );
};

const Pill: React.FC<{children: React.ReactNode; delay: number}> = ({children, delay}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const enter = spring({fps, frame: frame - delay, config: {damping: 20}});
  return (
    <div style={{padding: '19px 31px', borderRadius: 999, background: 'rgba(255,255,255,.08)', border: '1px solid rgba(255,255,255,.19)', fontSize: 25, fontWeight: 650, transform: `scale(${enter})`, opacity: enter}}>{children}</div>
  );
};

const Finale: React.FC = () => {
  const frame = useCurrentFrame();
  const title = interpolate(frame, [8, 38], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <Background>
      <Glow x={720} y={230} color="#0876b7" size={740} />
      <div style={{position: 'absolute', left: 0, right: 0, top: 82, textAlign: 'center', opacity: title}}>
        <Eyebrow>Built for your flow</Eyebrow>
        <div style={{fontSize: 87, fontWeight: 740, letterSpacing: -5}}>A browser that keeps up.</div>
      </div>
      <div style={{position: 'absolute', left: 180, right: 180, top: 285, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 38}}>
        <Device src="iphone-overview.png" width={280} radius={54} rotate={-7} delay={12} />
        <Device src="ipad-selection.png" width={830} radius={34} rotate={0} delay={4} />
        <Device src="iphone-ai.png" width={280} radius={54} rotate={7} delay={20} />
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, bottom: 52, display: 'flex', justifyContent: 'center', gap: 18}}>
        <Pill delay={28}>Split View</Pill>
        <Pill delay={34}>AI Assistant</Pill>
        <Pill delay={40}>Private by design</Pill>
      </div>
    </Background>
  );
};

const Outro: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const enter = spring({fps, frame: frame - 5, config: {damping: 20}});
  const shine = interpolate(frame, [16, 76], [-240, 240], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <Background>
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
        <div style={{textAlign: 'center', opacity: enter, transform: `scale(${interpolate(enter, [0, 1], [.9, 1])})`}}>
          <div style={{position: 'relative', fontSize: 148, fontWeight: 750, letterSpacing: -9, overflow: 'hidden'}}>
            Browser
            <div style={{position: 'absolute', top: -30, bottom: -30, left: `calc(50% + ${shine}px)`, width: 80, transform: 'skewX(-16deg)', background: 'rgba(255,255,255,.36)', filter: 'blur(18px)'}} />
          </div>
          <div style={{fontSize: 39, color: '#b8c0cb', marginTop: 24}}>Designed for the next way you work.</div>
        </div>
      </AbsoluteFill>
    </Background>
  );
};

const t = linearTiming({durationInFrames: 15});

export const BrowserFilm: React.FC = () => (
  <AbsoluteFill style={{backgroundColor: palette.ink}}>
    <Audio src={staticFile('browser-score.wav')} volume={0.58} />
    <TransitionSeries>
      <TransitionSeries.Sequence durationInFrames={90} premountFor={30}><Intro /></TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={t} />
      <TransitionSeries.Sequence durationInFrames={120} premountFor={30}><DeviceReveal /></TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={slide({direction: 'from-right'})} timing={t} />
      <TransitionSeries.Sequence durationInFrames={240} premountFor={30}><RecordingScene /></TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={wipe({direction: 'from-left'})} timing={t} />
      <TransitionSeries.Sequence durationInFrames={150} premountFor={30}><MultitaskScene /></TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={t} />
      <TransitionSeries.Sequence durationInFrames={150} premountFor={30}><AIScene /></TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={slide({direction: 'from-bottom'})} timing={t} />
      <TransitionSeries.Sequence durationInFrames={150} premountFor={30}><Finale /></TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={t} />
      <TransitionSeries.Sequence durationInFrames={90} premountFor={30}><Outro /></TransitionSeries.Sequence>
    </TransitionSeries>
    <Sequence from={0} durationInFrames={900}>
      <div style={{position: 'absolute', right: 42, bottom: 34, fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif', fontSize: 18, letterSpacing: 1.5, color: 'rgba(255,255,255,.38)'}}>BROWSER</div>
    </Sequence>
  </AbsoluteFill>
);
