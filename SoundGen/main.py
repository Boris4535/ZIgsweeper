import struct, math
import random



def generate_beep(rate=44100):
    dur = 0.1
    start_freq = 440
    end_freq = 880
    num_samples = int(rate * dur)
    samples = []
    for i in range(num_samples):

        t = i / num_samples
        freq = start_freq + (end_freq - start_freq) * t
        val = math.sin(2 * math.pi * freq * i / rate)

        sample = 32767 if val > 0 else -32767
        envelope = 1.0 - t

        samples.append(int(sample * envelope))
    return samples


def generate_explosion(rate=44100):
    dur = 0.5
    num_samples = int(rate * dur)
    samples = []
    for i in range(num_samples):
        t = i / num_samples

        white_noise = random.uniform(-1, 1)

        envelope = math.exp(-5 * t) 
        sample = int(white_noise * 32767 * envelope)
        samples.append(sample)
    return samples

def generate_crunch(rate=44100):
    dur = 0.05 
    num_samples = int(rate * dur)
    samples = []
    for i in range(num_samples):
        t = i / num_samples
        
        noise = random.uniform(-1, 1)
        
        envelope = (1.0 - t)**2
        sample = int(noise * 20000 * envelope) 
        samples.append(sample)
    return samples

def save_wav(filename, samples, rate=44100):
    data = struct.pack('<' + 'h' * len(samples), *samples)
    header = struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', 36+len(data), b'WAVE', b'fmt ', 16, 1, 1, rate, rate*2, 2, 16, b'data', len(data))
    with open(filename, 'wb') as f:
        f.write(header + data)
    print(f'{filename} scritto!')

save_wav('eat.wav', generate_beep())
save_wav('explosion.wav', generate_explosion())
save_wav('flag.wav', generate_crunch())


rate, freq, dur = 44100, 880, 0.08
samples = [int(32767 * math.sin(2 * math.pi * freq * i / rate)) for i in range(int(rate * dur))]
data = struct.pack('<' + 'h' * len(samples), *samples)
header = struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', 36+len(data), b'WAVE', b'fmt ', 16, 1, 1, rate, rate*2, 2, 16, b'data', len(data))
open('beep.wav', 'wb').write(header + data)
print('beep.wav written:', len(header+data), 'bytes')


