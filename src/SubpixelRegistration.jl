module SubpixelRegistration

using AbstractFFTs
using Compat
using FFTW
using Statistics

export phase_offset, register, coregister, coregister!, fourier_shift

"""
    phase_offset(source, target; upsample_factor=1)

Return the shift between `source` and `target` along each axis by measuring 
the maximum in the cross-correlation between the images. This algorithm can 
achieve `1/upsample_factor` precision by locally upsampling the cross-correlation 
via a matrix-multiplication DFT.[^1]

# Examples

```jldoctest
julia> image = reshape(1.0:100.0, 10, 10);

julia> shift = (-1.6, 2.8)
(-1.6, 2.8)

julia> target = fourier_shift(image, shift);

julia> phase_offset(image, target)
(shift = (2.0, -3.0), error = 0.9999999999997542, phasediff = 0.0)

julia> phase_offset(image, target; upsample_factor=5)
(shift = (1.8, -2.8), error = 0.9999999971143979, phasediff = 0.0)

julia> @. isapprox(ans.shift, -1 * shift, atol=1/5)
(true, true)
```

[^1]: Manuel Guizar-Sicairos, Samuel T. Thurman, and James R. Fienup, ["Efficient subpixel image registration algorithms,"](http://www.opticsinfobase.org/ol/fulltext.cfm?uri=ol-33-2-156&id=148843) Opt. Lett. 33, 156-158 (2008)
"""
function phase_offset(source::AbstractArray, target::AbstractArray; kwargs...)
    plan = plan_fft(source)
    return phase_offset(plan, plan * source, plan * target; kwargs...)
end

"""
    phase_offset(plan, source_freq, target_freq; upsample_factor=1)

Returns the phase shift between the two images which have already been
Fourier transformed with the given `plan`.
"""
function phase_offset(plan, source_freq::AbstractMatrix{Complex{T}}, 
                      target_freq; upsample_factor=1) where T
    # whole-pixel shift
    # compute cross-correlation via iFFT
    image_product = source_freq .* conj(target_freq)
    # phase normalization
    @. image_product /= max(abs(image_product), 100 * eps(T))
    # ifft to calculate cross correlation
    if isone(upsample_factor)
        # no upsampling means we can modify this array
        cross_correlation = ifft!(image_product)
    else
        cross_correlation = plan \ image_product
    end

    # locate maximums
    maxima, maxidx = @compat findmax(abs, cross_correlation)
    shape = size(source_freq)
    midpoints = map(ax -> (first(ax) + last(ax)) / T(2), axes(source_freq))
    idxoffset = map(first, axes(cross_correlation))
    shift = @. T(ifelse(maxidx.I > midpoints, maxidx.I - shape, maxidx.I) - idxoffset)

    isone(upsample_factor) && return (;shift, calculate_stats(maxima, source_freq, target_freq)...)

    # upsample with matrix-multiply DFT
    shift = @. round(shift * upsample_factor) / T(upsample_factor)
    upsample_region_size = ceil(upsample_factor * T(1.5))
    # center of output array at dftshift + 1
    dftshift = div(upsample_region_size, 2)
    # matmul DFT
    sample_region_offset = @. dftshift - shift * upsample_factor
    cross_correlation = upsampled_dft(image_product, upsample_region_size,
                                      upsample_factor, sample_region_offset)
    maxima, maxidx = @compat findmax(abs, cross_correlation)
    shift = @. shift + (maxidx.I - dftshift - idxoffset) / T(upsample_factor)

    stats = calculate_stats(maxima, source_freq, target_freq)
    return (;shift, stats...)
end

"""
    SubpixelRegistration.upsampled_dft(data, region_size, upsample_factor, offsets)

Calculate the cross-correlation in a region of size `region_size` via an upsampled DFT. 
The DFT uses matrix-multiplication to super-sample the input by `upsample_factor`. 
The frequencies will be shifted and centered around `offsets`.
"""
function upsampled_dft(data::AbstractMatrix{Complex{T}}, region_size,
                        upsample_factor, offsets) where T
    shiftrange = 1:region_size
    idxoffset = map(first, axes(data))
    sample_rate = inv(T(upsample_factor))
    freqs = fftfreq(size(data, 2), sample_rate)
    kernel = @. cis(-T(2π) * (shiftrange - offsets[2] - idxoffset[2]) * freqs')

    _data = kernel * data'

    freqs = fftfreq(size(data, 1), sample_rate)
    kernel = @. cis(T(2π) * (shiftrange - offsets[1] - idxoffset[1]) * freqs')
    _data = kernel * _data'
    return _data
end

"""
    SubpixelRegistration.calculate_stats(crosscor_maxima, source_freq, target_freq)

Calculate the normalized root-mean-square error (NRMSE) and total phase difference 
between the two complex arrays, `source_freq` and `target_freq`, with 
maximum cross-correlation value `crosscor_maxima`
"""
function calculate_stats(crosscor_maxima, source_freq, target_freq)
    source_amp = mean(abs2, source_freq)
    target_amp = mean(abs2, target_freq)
    error = 1 - abs2(crosscor_maxima) / (source_amp * target_amp)
    phasediff = atan(imag(crosscor_maxima), real(crosscor_maxima))
    return (; error, phasediff)
end

"""
    fourier_shift(image, shift)

Shift the given `image` by `shift` along each axis, using the Fourier phase information.
"""
function fourier_shift(image, shift, args...)
    FT = plan_fft(image)
    shifted = fourier_shift!(FT * image, shift, args...)
    return real(FT \ shifted)
end

"""
    fourier_shift!(image_freq::AbstractMatrix{<:Complex}, shift, phasediff=0)

Shift the given image, which is already in frequency-space, 
by `shift` along each axis. Modifies `image_freq` in place.
"""
function fourier_shift!(image_freq::AbstractMatrix{Complex{T}}, 
                        shift, phasediff=0) where T
    shape = size(image_freq)

    freqs1 = fftfreq(shape[1], one(T))
    freqs2 = fftfreq(shape[2], one(T))'
    @. image_freq *= cis(-T(2π) * (freqs1 * shift[1] + freqs2 * shift[2]) + phasediff)
    return image_freq
end

"""
    register(source, target; upsample_factor=1)

Register `target` image to `source` image by first finding the phase offset 
([`phase_offset`](@ref)), and then Fourier shifting `target` with [`fourier_shift`](@ref).

# Examples

```jldoctest
julia> image = reshape(1.0:100.0, 10, 10);

julia> shift = (-1.6, 2.8)
(-1.6, 2.8)

julia> target = fourier_shift(image, shift);

julia> target_shift = register(image, target; upsample_factor=5);
```

# See also
[`phase_offset`](@ref)
"""
function register(source, target; kwargs...)
    plan = plan_fft(source)
    target_freq = plan * target
    result = phase_offset(plan, plan * source, target_freq; kwargs...)
    shifted = fourier_shift!(target_freq, result.shift, result.phasediff)
    return real(plan \ shifted)
end

"""
    coregister(cube; dims, refidx=firstindex(cube, dims), upsample_factor=1)

Coregister a cube of data along `dims`, using the `refidx` slice as the source frame. 
Other keyword arguments will be passed to [`phase_offset`](@ref)

# See also
[`coregister!`](@ref)
"""
coregister(cube::AbstractArray; kwargs...) = coregister!(copy(cube); kwargs...)

"""
    coregister!(cube; dims, kwargs...)

Coregister slices in `cube`, modifying it in place.

# See also
[`coregister`](@ref)
"""
function coregister!(cube::AbstractArray; dims, refidx=firstindex(cube, dims), kwargs...)
    source = selectdim(cube, dims, refidx)
    plan = plan_fft(source)
    source_freq = plan * source
    @inbounds for idx in axes(cube, dims)[begin + 1:end]
        target = selectdim(cube, dims, idx)
        target_freq = plan * target
        # measure offset and fourier shift
        result = phase_offset(plan, source_freq, target_freq; kwargs...)
        fourier_shift!(target_freq, result.shift, result.phasediff)
        # target is a view, update in place
        target .= real.(plan \ target_freq)
    end
    return cube
end

end
