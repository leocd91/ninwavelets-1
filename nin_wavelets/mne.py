import numpy as np
import cupy
from mpl_toolkits.mplot3d import Axes3D
import matplotlib.pyplot as plt
from scipy.fftpack import ifft, fft
from typing import Union, List, Tuple, Iterator, Iterable, Type
from enum import Enum
from nin_wavelets.base import WaveletBase, WaveletMode, Numbers
from nin_wavelets import Morlet, Morse, MorseMNE, Haar
from mne import Epochs, Evoked
from mne.io import Raw


class EpochsWavelet:
    '''
    A class to perform wavelet transform to mne.Epochs.
    >>> epochs = mne.Epochs(fname)
    >>> data = epochs.get_data()
    >>> wavelet = Morlet()
    >>> result = mne.RawWavelet(raw, wavelet).cwt()
    >>> power = mne.RawWavelet(raw, wavelet).power()
    >>> itc = mne.RawWavelet(raw, wavelet).itc()
    '''
    def __init__(self, epochs: Epochs, wavelet: Type[WaveletBase]) -> None:
        '''
        Parameters
        ====================
        epochs: mne.Epochs
            Epochs of mne.
        wavelet: instance of wavelet
            wavelet is union of wavelet objects, defined as below.
        '''
        self.epochs = epochs
        self.wavelet = wavelet
        wavelet.sfreq = self.epochs.info['sfreq']

    def cwt(self, ch_name: str, freqs: Numbers) -> np.ndarray:
        ''' cwt
        Just a method to perform cwt.

        Parameters
        ====================
        wave: np.ndarray
            Wave to transform.
        freqs: Union[List[float], range, np.ndarray]
            Frequencies to analyze.
        '''
        wave_index = self.epochs.ch_names.index(ch_name)
        waves = self.epochs.get_data()[:, wave_index, :]
        results = map(lambda wave: self.wavelet.cwt(wave, freqs), waves)
        return np.array(list(results))

    def power(self, ch_name: str, freqs: Numbers) -> np.ndarray:
        ''' power
        Just a method to perform cwt, and calculate mean of power.

        Parameters
        ====================
        wave: np.ndarray
            Wave to transform.
        freqs: Union[List[float], range, np.ndarray]
            Frequencies to analyze.
        '''
        absolute = np.abs(self.cwt(ch_name, freqs))
        power = absolute ** 2
        return np.mean(power, axis=0)

    def itc(self, ch_name: str, freqs: Numbers) -> np.ndarray:
        ''' itc
        Just a method to perform cwt and calculate intertrial coherence.

        Parameters
        ====================
        wave: np.ndarray
            Wave to transform.
        freqs: Union[List[float], range, np.ndarray]
            Frequencies to analyze.
        '''
        cwt = self.cwt(ch_name, freqs)
        angle = cwt / np.abs(cwt)
        total_angle = np.mean(angle, axis=0)
        return np.abs(total_angle)
