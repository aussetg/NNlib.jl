# batch-wise matrix multiplication,
# including a wrapper for batched_gemm!

export batched_mul, batched_transpose, batched_adjoint

using LinearAlgebra: BlasFloat

include("./batchedadjtrans.jl")

"""
    batched_mul(A, B) -> C

Batched matrix multiplication. Result has `C[:,:,k] == A[:,:,k] * B[:,:,k]` for all `k`.

Using `batched_transpose(A)` will transpose each `A[:,:,k]`,
and similarly `batched_adjoint(B)` will use `adjoint(B[:,:,k])`.

It will also accept `A` or `B` which are `PermutedDimsArray{T,3}`.
On the CPU, these will still be handled by `BLAS.gemm!` provided `T <: LinearAlgebra.BlasFloat`
and the can be permuted to be column-major. For `T <: Real` this allows any permutations
so long as `Base.stride(A,3) != 1` and `Base.stride(B,3) != 1`.
For `T <: Complex` instead you must have `Base.stride(A,1) == 1 == Base.stride(B,1)`.

Other cases will fall back to `batched_mul_generic!`, which logs a message via `@debug`.
```
julia> A = PermutedDimsArray(rand(5,4,10), (2,1,3)); size(A)
(4, 5, 10)

julia> strides(A)
(5, 1, 20)

julia> B = PermutedDimsArray(rand(5,10,6), (1,3,2)); size(B)
(5, 6, 10)

julia> strides(B)
(1, 50, 5)

julia> ENV["JULIA_DEBUG"] = NNlib;

julia> C = batched_mul(A, B); size(C)
(4, 6, 10)
```
On the GPU, all permutations of dimensions are handled by `gemm_batched_strided` I think.
"""
function batched_mul(A::AbstractArray{T1, 3}, B::AbstractArray{T2, 3}) where {T1, T2}
    axes(A, 3) == axes(B, 3) || throw(DimensionMismatch("batch size mismatch"))
    T = promote_type(T1, T2)
    C = similar(A, T, (axes(A, 1), axes(B, 2), axes(A, 3)))
    batched_mul!(C, A, B)
end

"""
    batched_mul!(C, A, B) -> C

In-place batched matrix multiplication,
equivalent to `mul!(C[:,:,k], A[:,:,k], B[:,:,k])` for all `k`.
"""
function batched_mul! end

_unbatch(A) = A
_unbatch(A::BatchedAdjOrTrans) = A.parent

# batched_gemm! is happy with PermutedDimsArray, which is not StridedArray, but needs:
# (1) all same eltype <: BlasFloat, and
# (2) all with Base.stride(X,1) == 1 where A,B might be batched_adjoint(X) etc.

# const SuperStrided2 = Union{StridedArray, BatchedAdjOrTrans, PermutedDimsArray{T,N,P,Q,<:StridedArray} where {T,N,P,Q}}
#
# function batched_mul!(C::AbstractArray{<:Any,3}, A::AbstractArray{<:Any,3}, B::AbstractArray{<:Any,3})
#     if A isa SuperStrided2 && B isa SuperStrided2 && C isa StridedArray
#         batched_try_gemm!(C, A, B)
#     else
#         batched_mul_generic!(C, A, B)
#     end
# end
# This "batched_try_gemm!" thing attempts to be careful about e.g. some views for strides(A) is an error. But I'm not sure it's worth bothering.

_BATCHED_GEMM_LIST = [
    (:(AbstractArray{T, 3}), 'N', :identity),
    (:(BatchedTranspose{T, <:AbstractArray{T, 3}}), 'T', :batched_transpose),
    (:(BatchedAdjoint{T, <:AbstractArray{T, 3}}), 'C', :batched_adjoint)
]

for (TA, transA, fA) in _BATCHED_GEMM_LIST, (TB, transB, fB) in _BATCHED_GEMM_LIST

    # @eval function batched_try_gemm!(C::AbstractArray{T, 3}, A::$TA, B::$TB) where {T<:BlasFloat}
    @eval function batched_mul!(C::AbstractArray{T, 3}, A::$TA, B::$TB) where {T<:BlasFloat}
        Abase, Bbase = _unbatch(A), _unbatch(B)

        # Best case, we can call batched_gemm! immediately:
        if Base.stride(Abase,1) == Base.stride(Bbase,1) == Base.stride(C,1) == 1
            batched_gemm!($transA, $transB, one(T), _unbatch(A), _unbatch(B), zero(T), C)

        # Second-best, can we fix it by Perm.ing the base, and adjusing 'T' label?
        # But only if we won't produce BatchedTranspose(BatchedAdjoint(complex array)).
        elseif Base.stride(Abase,2) == 1 && !(T<:Complex && $TA<:BatchedAdjoint)
            newAbase = batched_transpose(PermutedDimsArray(Abase, (2,1,3)))
            # return batched_try_gemm!(C, $fA(newAbase), B)
            return batched_mul!(C, $fA(newAbase), B)
        elseif Base.stride(Bbase,2) == 1 && !(T<:Complex && $TB<:BatchedAdjoint)
            newBbase = batched_transpose(PermutedDimsArray(Bbase, (2,1,3)))
            # return batched_try_gemm!(C, A, $fB(newBbase))
            return batched_mul!(C, A, $fB(newBbase))

        # Fallback, e.g when Base.stride(A,3)==1
        else
            batched_mul_generic!(C, A, B)
        end
        C
    end

end

# fallback

batched_mul!(C::AbstractArray{<:Any,3}, A::AbstractArray{<:Any,3}, B::AbstractArray{<:Any,3}) = batched_mul_generic!(C, A, B)

_BATCHED_LIST = [
    (:(AbstractArray{<:Any, 3}), :identity),
    (:BatchedTranspose, :transpose),
    (:BatchedAdjoint, :adjoint),
]
for (TA, fA) in _BATCHED_LIST, (TB, fB) in _BATCHED_LIST

    @eval function batched_mul_generic!(C::AbstractArray{<:Any, 3}, A::$TA, B::$TB)
        axes(A, 3) == axes(B, 3) == axes(C, 3) || throw(DimensionMismatch("batch size mismatch"))
        @debug "calling fallback method for batched_mul!" typeof(A) typeof(B) typeof(C)
        Abase, Bbase = _unbatch(A), _unbatch(B)
        @inbounds for k in axes(C, 3)
            @views mul!(C[:,:,k], $fA(Abase[:,:,k]), $fB(Bbase[:,:,k]))
        end
        C
    end

end