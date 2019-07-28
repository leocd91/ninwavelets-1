import numpy as np
import cupy
from mpl_toolkits.mplot3d import Axes3D
import matplotlib.pyplot as plt
from scipy.fftpack import ifft, fft
from typing import Union, List, Tuple, Iterator, Iterable
from enum import Enum
cimport numpy as np
import cython as c
DTYPE_COMPLEX = np.complex


cdef kill_nyquist(np.ndarray[np.complex128_t, ndim=1]wave):
    '''
    Kill wave over Nyquist frequency.
    Not a method to kill Mr Nyquist, I am sorry.
    '''
    half_size: c.int = int(wave.shape[0] / 2)
    wave = np.pad(wave[:half_size],
                  [0, wave.shape[0] - half_size],
                  'constant', constant_values=0)
    return wave


cdef nin_fft(np.ndarray[np.complex128_t, ndim=1]wave):
    '''
    FFT without nyquist freq.
    '''
    return kill_nyquist(fft(wave))


class WaveletMode(Enum):
    Normal = 0
    Both = 1
    Reverse = 2
    Indifferentiable = 3
    Twice = 4


cdef class WaveletBase:
    '''
    Base class of wavelets.
    You need to write methods to make single wavelet.
    self._make_fft_wavelet : returns np.ndarray
    self.make_wavelet : returns np.ndarray
    '''
    def __init__(self, sfreq: c.float) -> None:
        self.mode = WaveletMode.Normal
        self.accuracy: c.float = 1
        self.sfreq = sfreq
        self.length: c.float = 10
        self.help: c.str = ''
        self.use_cuda: c.bool = False
        self.base_freq: c.float = 1
        self.real_wave_length: c.float = 1

    cdef _setup_base_trans_waveshape(self, freq: c.float,
                                    real_length: c.float = 1):
        '''
        Setup wave shape.
        real_length is length of wavelet(for example, sec or msec)
        self.real_wave_length is length of wave to analyze.

        Parameters
        ----------
        freq: float | Base Frequency. For example, 1.
            It must be base frequency.
            You cannot use this for every freqs.

        Returns
        -------
        np.ndarray | Timeline to calculate wavelet.
        '''
        one: c.float = 1 / freq / self.accuracy / real_length
        total: c.float = self.sfreq / freq / real_length * self.real_wave_length
        return np.arange(0, total, one, dtype=np.float)

    cdef _setup_base_waveletshape(self, freq: c.float, real_length: c.float = 1,
                                 zero_mean: bool = False):
        '''
        Setup wave shape.

        Parameters
        ----------
        freq: float | Base Frequency. For example, 1.
            It must be base frequency.
            You cannot use this for every freqs.

        Returns
        -------
        Tuple[float, float]: (one, total)
        '''
        total: c.float = real_length / self.peak_freq(freq) * freq * 2 * np.pi
        one: c.float = 1 / self.sfreq * 2 * np.pi * freq / self.peak_freq(freq)
        if zero_mean:
            return np.arange(-total / 2, total / 2, one)
        return np.arange(0, total, one)

    def peak_freq(self, freq: c.float) -> float:
        return 1.

    cdef _normalize(self, np.ndarray[np.complex128_t, ndim=1] wave):
        wave /= np.linalg.norm(wave.ravel()) * np.sqrt(0.5)
        return wave

    cpdef make_fft_wavelet(self, freq: c.float = 1.):
        if self.mode in [WaveletMode.Reverse, WaveletMode.Both]:
            timeline = self._setup_base_trans_waveshape(self.real_wave_length)
            result = np.asarray(self.trans_wavelet_formula(timeline, freq),
                                dtype=np.complex128)
            return self._normalize(result)
        else:
            wavelet = self.make_wavelet(freq)
            wavelet = wavelet.astype(np.complex128)
            half = int((self.sfreq *
                        self.real_wave_length - wavelet.shape[0]) / 2),

            wavelet = np.hstack((np.zeros(half, dtype=np.complex128),
                                 wavelet,
                                 np.zeros(half, dtype=np.complex128)))
            wavelet = wavelet.astype(np.complex128)
            result = fft(wavelet) / self.sfreq
            result.imag = np.abs(result.imag)
            result.real = np.abs(result.real)
            result = self._normalize(result)
            return result

    def make_fft_wavelets(self, freqs: Iterable) -> Iterator:
        '''
        Make Fourier transformed wavelet.
        '''
        self.fft_wavelets = []
        for x in freqs:
            self.fft_wavelets.append(self.make_fft_wavelet(x))
        return self.fft_wavelets

    def wavelet_formula(self, timeline: np.ndarray, freq: c.float) -> np.ndarray:
        return timeline

    def trans_wavelet_formula(self, timeline: np.ndarray,
                              freq: c.float = 1.) -> np.ndarray:
        return timeline

    cpdef make_wavelet(self, freq: c.float):
        if self.mode in [WaveletMode.Reverse, WaveletMode.Twice]:
            timeline: np.ndarray = self._setup_base_trans_waveshape(freq)
            wave = self.trans_wavelet_formula(timeline)
            wavelet: np.ndarray = ifft(wave)
            half = int(wavelet.shape[0])
            band = int(half / 2 / freq * self.length)
            start: int = half - band if band < half // 2 else half // 2
            stop: int = half + band if band < half // 2 else half // 2 * 3
            start: int = half // 2
            stop: int = half // 2 * 3
            # cut side of wavelets and contactnate
            total_wavelet = np.hstack((np.conj(np.flip(wavelet)),
                                       wavelet))
            wavelet: np.ndarray = total_wavelet[start: stop]
        else:
            timeline: np.ndarray = self._setup_base_waveletshape(freq, 1, zero_mean=True)
            wavelet: np.ndarray = np.asarray(self.wavelet_formula(timeline, freq),
                                             dtype=np.complex128)
        return self._normalize(wavelet)

    cpdef make_wavelets(self, freqs: Union[List[float], range, np.ndarray]):
        '''
        Make wavelets.
        It returnes list of wavelet, and it is compatible with mne-python.
        (As argument of Ws of mne.time_frequency.tfr.cwt)

        Parameters
        ----------
        freqs: List[float] | Frequency. If frequency is too small,
            it returnes bad wave easily.
            For example, sfreq=1000, freq=3 it returnes bad wave.
            If you want good wave, you must set large accuracy, and length
            when you make this instance.

        Returns
        -------
        MorseWavelet: np.ndarray
        '''
        self.wavelets: c.list = []
        for freq in freqs:
            self.wavelets.append(self.make_wavelet(freq))
        return self.wavelets

    def cwt(self, wave: np.ndarray,
            freqs: Union[List[float], range, np.ndarray],
            max_freq: int = 0,
            kill_nyquist: bool = False):
        '''cwt
        Run CWT.
        This method is still experimental.

        wave:
        freqs:
        max_freq:
        '''
        wave2: complex128_t[:] = wave
        freq_dist: c.int = freqs[1] - freqs[0]
        wave_length: c.int = wave.shape[0]
        self.real_wave_length: c.float = wave.shape[0] / self.sfreq
        # wavelet_base = np.asarray(self.make_fft_wavelets(freqs), dtype=np.complex128)
        wavelet_base = self.make_fft_wavelets(freqs)
        wavelet = []
        for x in wavelet_base:
            wavelet.append(np.pad(x, [0, wave_length - x.shape[0]], 'constant'))
        fft_wave = nin_fft(wave2) if kill_nyquist else fft(wave2)
        # Keep powerful even if long wave.
        fft_wave *= (wave_length / self.sfreq) ** 0.5
        result_map = []
        for x in wavelet:
            result_map.append(ifft(x * fft_wave))
        if max_freq == 0:
            max_freq = int(self.sfreq / freq_dist)
        result_list = result_map[:max_freq]
        # reset myself
        self.real_wave_length = 1.
        return np.array(result_list)

    def power(self, wave: np.ndarray,
              freqs: Union[List[float], range, np.ndarray],
              kill_nyquist: bool = False) -> np.ndarray:
        '''
        Run cwt and compute power.

        Parameters
        ----------
        freqs: float | Frequencies. Before use this, please run plot.

        Returns
        -------
        Result of cwt. np.ndarray.
        '''
        result: np.ndarray[np.complex128_t] = self.cwt(wave, freqs, kill_nyquist=kill_nyquist)
        return np.abs(result)

    def plot(self, freq: float, show: bool = True) -> plt.figure:
        if self.help == '':
            plt_num = 3
        wavelet = self.make_wavelets([freq])[0]
        fig = plt.figure(figsize=(6, 8))
        ax = fig.add_subplot(plt_num, 1, 1)
        ax.plot(np.arange(0, wavelet.shape[0], 1),
                wavelet,
                label='morse')
        ax1 = fig.add_subplot(plt_num, 1, 2, projection='3d')
        ax1.scatter3D(wavelet.real,
                      np.arange(0, wavelet.shape[0], 1),
                      wavelet.imag,
                      label='morse')
        ax.set_title('Generalized Morse Wavelet')
        if plt_num == 3:
            ax2 = fig.add_subplot(313)
            ax2.set_title('Caution')
            ax2.text(0.05, 0.1, self.help)
            ax2.tick_params(labelbottom=False,
                            labelleft=False,
                            labelright=False,
                            labeltop=False,
                            bottom=False,
                            left=False,
                            right=False,
                            top=False)
        if show:
            plt.show()
        fig


