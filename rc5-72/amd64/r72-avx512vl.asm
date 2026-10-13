; RC5-72 AVX-512VL core (256-bit Vector Length)
; 32-Pipeline (32-Key) Implementation
; Created by Mix
; Inspired by Yasuhiro Katsui's AVX2 core
;
; 32-pipeline core (four 8-wide pipelines on 256-bit YMM registers)
; Uses native 1-cycle vector rotate instructions (VPROLVD / VPROLD)
; Uses EVEX-compliant vmovdqa32 and vpxord mnemonics for ymm16-ymm31
; Requires: AVX-512F + AVX-512VL (or AVX10/256)
; Compatible with: AMD Zen 4, Zen 5; Intel 10th/11th Gen+, Xeon Scalable

section .text
BITS 64

[GLOBAL _rc5_72_unit_func_avx512vl]
[GLOBAL rc5_72_unit_func_avx512vl]

%define _mm512_set1_d(N) N,N,N,N,N,N,N,N,N,N,N,N,N,N,N,N

%define RESULT_NOTHING 1
%define RESULT_FOUND   2

%assign work_size 0

%macro defidef 2
    %define %1 rsp+%2
%endmacro

%macro defwork 1-2 1
    defidef %1,work_size
    %assign work_size work_size+4*(%2)
%endmacro

%assign work32_size 0

%macro defidef32 2
    %define %1 rbp+%2
%endmacro

%macro defwork32 1-2 1
    defidef32 %1,work32_size
    %assign work32_size work32_size+32*(%2)
%endmacro

; local storage variables - referenced via [RSP+xxx]

%ifdef _WINDOWS
defwork save_xmm6,4
defwork save_xmm7,4
defwork save_xmm8,4
defwork save_xmm9,4
defwork save_xmm10,4
defwork save_xmm11,4
defwork save_xmm12,4
defwork save_xmm13,4
defwork save_xmm14,4
defwork save_xmm15,4
defwork save_rsi,2
defwork save_rdi,2
%endif
defwork save_rbx,2
defwork save_rbp,2
defwork save_r12,2
defwork save_r13,2
defwork save_r14,2
defwork save_r15,2

; Following variables will be relocated BEFORE RBP
defwork work_pre_B_0
defwork work_pre_B_1
defwork work_pre_B_2
defwork work_pre_S1
defwork work_pre_S2

; Second pool of variables - aligned by 32, referenced via [RBP+xxx]
%assign work_size work_size + 32
%assign work_offset work_size

defwork32 work_C_0
defwork32 work_C_1
defwork32 work_S, (26*4)    ; 4 pipes * 32 bytes = 128 bytes per subkey

; Concatenate two work areas together
%assign work_size work_size + work32_size
%assign work_size (work_size + 7) & 0FFFFFFF8h
%assign work_size work_size + (8 - work_size % 16)

;; offsets within the parameter structure
%define RC5_72UnitWork_plainhi  rdi+0
%define RC5_72UnitWork_plainlo  rdi+4
%define RC5_72UnitWork_cipherhi rdi+8
%define RC5_72UnitWork_cipherlo rdi+12
%define RC5_72UnitWork_L0hi     rdi+16
%define RC5_72UnitWork_L0mid    rdi+20
%define RC5_72UnitWork_L0lo     rdi+24
%define RC5_72UnitWork_CMCcount rdi+28
%define RC5_72UnitWork_CMChi    rdi+32
%define RC5_72UnitWork_CMCmid   rdi+36
%define RC5_72UnitWork_CMClo    rdi+40

; Manually move "RBP-minus" variables to their positions.
%undef  work_pre_B_0
%define work_pre_B_0            rbp-20
%undef  work_pre_B_1
%define work_pre_B_1            rbp-16
%undef  work_pre_B_2
%define work_pre_B_2            rbp-12
%undef  work_pre_S1
%define work_pre_S1             rbp-8
%undef  work_pre_S2
%define work_pre_S2             rbp-4

; 128-byte stride per subkey for 4 pipes
%define S1(N)   [work_S+((N)*128)]
%define S2(N)   [work_S+((N)*128)+32]
%define S3(N)   [work_S+((N)*128)+64]
%define S4(N)   [work_S+((N)*128)+96]

%define L0hi    r13d
%define L0mid   r14d
%define L0lo    r15d

; Scratch Registers
%define T1      ymm0
%define T2      ymm1
%define T3      ymm2
%define T4      ymm3

; Pipe 1 (Keys 0-7)
%define A1      ymm6
%define B1_0    ymm8
%define B1_1    ymm9
%define B1_2    ymm10
%define C1      ymm8
%define D1      ymm11

; Pipe 2 (Keys 8-15)
%define A2      ymm7
%define B2_0    ymm11
%define B2_1    ymm12
%define B2_2    ymm13
%define C2      ymm10
%define D2      ymm13

; Pipe 3 (Keys 16-23)
%define A3      ymm16
%define B3_0    ymm17
%define B3_1    ymm18
%define B3_2    ymm19
%define C3      ymm17
%define D3      ymm19

; Pipe 4 (Keys 24-31)
%define A4      ymm20
%define B4_0    ymm21
%define B4_1    ymm22
%define B4_2    ymm23
%define C4      ymm21
%define D4      ymm23

align 16
startseg:
_rc5_72_unit_func_avx512vl:
rc5_72_unit_func_avx512vl:

    sub     rsp, work_size

%ifdef _WINDOWS
    vmovdqa [save_xmm6], xmm6
    vmovdqa [save_xmm7], xmm7
    vmovdqa [save_xmm8], xmm8
    vmovdqa [save_xmm9], xmm9
    vmovdqa [save_xmm10], xmm10
    vmovdqa [save_xmm11], xmm11
    vmovdqa [save_xmm12], xmm12
    vmovdqa [save_xmm13], xmm13
    vmovdqa [save_xmm14], xmm14
    vmovdqa [save_xmm15], xmm15
    mov     [save_rsi], rsi
    mov     [save_rdi], rdi
    mov     rdi, rcx
    mov     rsi, rdx
%endif
    mov     [save_rbx], rbx
    mov     [save_rbp], rbp
    mov     [save_r12], r12
    mov     [save_r13], r13
    mov     [save_r14], r14
    mov     [save_r15], r15

    lea     rbp, [rsp+work_offset]
    and     rbp, -32

    mov     r10d, [rsi]
    shr     r10d, 5           ; Divide by 32 keys per batch

    vpbroadcastd    T1, [RC5_72UnitWork_cipherlo]
    vpbroadcastd    T2, [RC5_72UnitWork_cipherhi]
    vmovdqa32       [work_C_0], T1
    vmovdqa32       [work_C_1], T2

    mov     L0hi, [RC5_72UnitWork_L0hi]
    mov     L0mid, [RC5_72UnitWork_L0mid]
    mov     L0lo, [RC5_72UnitWork_L0lo]

    lea     r12, S1(1)

.key_setup_1_outer_loop:
    mov     ecx, L0lo
    add     ecx, 0xBF0A8B1D
    rol     ecx, 29
    mov     [work_pre_B_0], ecx

    mov     eax, ecx
    add     eax, 0x15235639
    rol     eax, 3
    mov     [work_pre_S1], eax
    add     ecx, eax

.key_setup_1_mid_loop:
    lea     edx, [L0mid+ecx]
    rol     edx, cl
    mov     [work_pre_B_1], edx

    add     eax, edx
    add     eax, 0xF45044D5
    rol     eax, 3
    mov     [work_pre_S2], eax
    add     edx, eax
    mov     [work_pre_B_2], edx

align 16
.key_setup_1_inner_loop:
    vpbroadcastd    A1, [work_pre_S2]
    vpbroadcastd    B1_0, [work_pre_B_0]
    vpbroadcastd    B1_1, [work_pre_B_1]
    vmovdqa32       A2, A1
    vmovdqa32       B2_0, B1_0
    vmovdqa32       B2_1, B1_1
    vmovdqa32       A3, A1
    vmovdqa32       B3_0, B1_0
    vmovdqa32       B3_1, B1_1
    vmovdqa32       A4, A1
    vmovdqa32       B4_0, B1_0
    vmovdqa32       B4_1, B1_1

    vpbroadcastd    T1, [work_pre_S1]
    vmovdqa32 S1(1), T1
    vmovdqa32 S2(1), T1
    vmovdqa32 S3(1), T1
    vmovdqa32 S4(1), T1
    vmovdqa32 S1(2), A1
    vmovdqa32 S2(2), A1
    vmovdqa32 S3(2), A1
    vmovdqa32 S4(2), A1

    vpbroadcastd    B1_2, [RC5_72UnitWork_L0hi]
    vpbroadcastd    T1, [work_pre_B_2]
    vmovdqa32       B2_2, B1_2
    vmovdqa32       B3_2, B1_2
    vmovdqa32       B4_2, B1_2
    vmovdqa32       T2, T1
    vmovdqa32       T3, T1
    vmovdqa32       T4, T1

    ; Pre-rotate B natively
    vpaddd  B1_2, B1_2, [rel .I1]
    vpaddd  B1_2, B1_2, T1
    vprolvd B1_2, B1_2, T1

    vpaddd  B2_2, B2_2, [rel .I2]
    vpaddd  B2_2, B2_2, T2
    vprolvd B2_2, B2_2, T2

    vpaddd  B3_2, B3_2, [rel .I3]
    vpaddd  B3_2, B3_2, T3
    vprolvd B3_2, B3_2, T3

    vpaddd  B4_2, B4_2, [rel .I4]
    vpaddd  B4_2, B4_2, T4
    vprolvd B4_2, B4_2, T4

    lea     rax, [rel .IS3]
    lea     rdx, S1(3)
    lea     r8, [work_S - 128]       ; Pre-load wrap target for branchless cmove
    xor     ebx, ebx
    jmp     .round1

align 16
.round:
    ; === STEP A ===
    ; 1. Issue all 4 loads early
    vpaddd  A1, A1, [rax-128]
    cmp     ebx, 7
    cmove   rdx, r12                 ; Branchless wrap to S[1]
    vpaddd  A2, A2, [rax-96]
    vpaddd  A3, A3, [rax-64]
    vpaddd  A4, A4, [rax-32]

    ; 2. Add B_1 into A:
    vpaddd  A1, A1, B1_1
    vpaddd  A2, A2, B2_1
    vpaddd  A3, A3, B3_1
    vpaddd  A4, A4, B4_1
    add     ebx, 1

    ; 3. Fixed rotates:
    vprold  A1, A1, 3
    vprold  A2, A2, 3
    vprold  A3, A3, 3
    vprold  A4, A4, 3

    ; 4. Stores to stack:
    vmovdqa32 [rdx-128], A1
    vmovdqa32 [rdx-96],  A2
    vmovdqa32 [rdx-64],  A3
    vmovdqa32 [rdx-32],  A4

    ; 5. T = B_1 + A:
    vpaddd  T1, B1_1, A1
    vpaddd  T2, B2_1, A2
    vpaddd  T3, B3_1, A3
    vpaddd  T4, B4_1, A4

    ; 6. Add T into B_2:
    vpaddd  B1_2, B1_2, T1
    vpaddd  B2_2, B2_2, T2
    vpaddd  B3_2, B3_2, T3
    vpaddd  B4_2, B4_2, T4

    ; 7. Variable rotate B_2 by T:
    vprolvd B1_2, B1_2, T1
    vprolvd B2_2, B2_2, T2
    vprolvd B3_2, B3_2, T3
    vprolvd B4_2, B4_2, T4

.round1:
    ; === STEP B ===
    cmp     ebx, 8
    cmove   rax, rdx                 ; Branchless switch from ROM constants to RAM subkeys

    ; 1. Loads:
    vpaddd  A1, A1, [rax]
    vpaddd  A2, A2, [rax+32]
    vpaddd  A3, A3, [rax+64]
    vpaddd  A4, A4, [rax+96]

    ; 2. Add B_2 into A:
    vpaddd  A1, A1, B1_2
    vpaddd  A2, A2, B2_2
    vpaddd  A3, A3, B3_2
    vpaddd  A4, A4, B4_2

    ; 3. Fixed rotates:
    vprold  A1, A1, 3
    vprold  A2, A2, 3
    vprold  A3, A3, 3
    vprold  A4, A4, 3

    ; 4. Stores:
    vmovdqa32 [rdx],    A1
    vmovdqa32 [rdx+32], A2
    vmovdqa32 [rdx+64], A3
    vmovdqa32 [rdx+96], A4

    ; 5. T = B_2 + A:
    vpaddd  T1, B1_2, A1
    vpaddd  T2, B2_2, A2
    vpaddd  T3, B3_2, A3
    vpaddd  T4, B4_2, A4

    ; 6. Add T into B_0:
    vpaddd  B1_0, B1_0, T1
    vpaddd  B2_0, B2_0, T2
    vpaddd  B3_0, B3_0, T3
    vpaddd  B4_0, B4_0, T4

    ; 7. Variable rotate B_0 by T:
    vprolvd B1_0, B1_0, T1
    vprolvd B2_0, B2_0, T2
    vprolvd B3_0, B3_0, T3
    vprolvd B4_0, B4_0, T4

    ; === STEP C ===
    cmp     ebx, 16
    cmove   rdx, r8                  ; Branchless wrap to S[0]
    cmove   rax, r8

    ; 1. Loads:
    vpaddd  A1, A1, [rax+128]
    vpaddd  A2, A2, [rax+160]
    vpaddd  A3, A3, [rax+192]
    vpaddd  A4, A4, [rax+224]

    ; 2. Add B_0 into A:
    vpaddd  A1, A1, B1_0
    vpaddd  A2, A2, B2_0
    vpaddd  A3, A3, B3_0
    vpaddd  A4, A4, B4_0

    ; 3. Fixed rotates:
    vprold  A1, A1, 3
    vprold  A2, A2, 3
    vprold  A3, A3, 3
    vprold  A4, A4, 3

    ; 4. Stores:
    vmovdqa32 [rdx+128], A1
    vmovdqa32 [rdx+160], A2
    vmovdqa32 [rdx+192], A3
    vmovdqa32 [rdx+224], A4

    ; 5. T = B_0 + A:
    vpaddd  T1, B1_0, A1
    vpaddd  T2, B2_0, A2
    vpaddd  T3, B3_0, A3
    vpaddd  T4, B4_0, A4

    ; 6. Add T into B_1:
    vpaddd  B1_1, B1_1, T1
    vpaddd  B2_1, B2_1, T2
    vpaddd  B3_1, B3_1, T3
    vpaddd  B4_1, B4_1, T4

    ; 7. Variable rotate B_1 by T:
    vprolvd B1_1, B1_1, T1
    vprolvd B2_1, B2_1, T2
    vprolvd B3_1, B3_1, T3
    vprolvd B4_1, B4_1, T4

    add     rax, 384
    add     rdx, 384
    cmp     ebx, 24
    jne     .round

.encryptSetup:
    ; C = plainlo + S[0], D = plainhi + S[1]
    vpbroadcastd  T1, [RC5_72UnitWork_plainlo]
    vpbroadcastd  T3, [RC5_72UnitWork_plainhi]
    
    vpaddd  C1, T1, S1(0)
    vpaddd  D1, T3, S1(1)
    vpaddd  C2, T1, S2(0)
    vpaddd  D2, T3, S2(1)
    vpaddd  C3, T1, S3(0)
    vpaddd  D3, T3, S3(1)
    vpaddd  C4, T1, S4(0)
    vpaddd  D4, T3, S4(1)

    ; rax points to S[2] (Round 1 subkeys)
    lea     rax, [work_S + 2*128]
    xor     ebx, ebx

align 16
.encrypt:
    inc     ebx

    ; C = ((C ^ D) <<< D) + S[2r]
    vpxord  C1, C1, D1
    vpxord  C2, C2, D2
    vpxord  C3, C3, D3
    vpxord  C4, C4, D4

    vprolvd C1, C1, D1
    vprolvd C2, C2, D2
    vprolvd C3, C3, D3
    vprolvd C4, C4, D4

    vpaddd  C1, C1, [rax]
    vpaddd  C2, C2, [rax+32]
    vpaddd  C3, C3, [rax+64]
    vpaddd  C4, C4, [rax+96]

    ; D = ((D ^ C) <<< C) + S[2r+1]
    vpxord  D1, D1, C1
    vpxord  D2, D2, C2
    vpxord  D3, D3, C3
    vpxord  D4, D4, C4

    vprolvd D1, D1, C1
    vprolvd D2, D2, C2
    vprolvd D3, D3, C3
    vprolvd D4, D4, C4

    vpaddd  D1, D1, [rax+128]
    vpaddd  D2, D2, [rax+160]
    vpaddd  D3, D3, [rax+192]
    vpaddd  D4, D4, [rax+224]

    add     rax, 256                 ; Advance 2 subkeys (2 * 128 bytes)
    cmp     ebx, 11
    jne     .encrypt

.encryptEnd:
    ; Final half-round: C = ((C ^ D) <<< D) + S[24]
    ; We defer computing D until we verify if C matches cipherlo
    vpxord  C1, C1, D1
    vpxord  C2, C2, D2
    vpxord  C3, C3, D3
    vpxord  C4, C4, D4

    vprolvd C1, C1, D1
    vprolvd C2, C2, D2
    vprolvd C3, C3, D3
    vprolvd C4, C4, D4

    vpaddd  C1, C1, S1(24)
    vpaddd  C2, C2, S2(24)
    vpaddd  C3, C3, S3(24)
    vpaddd  C4, C4, S4(24)

.checkKey1:
    ; Check if any of the 8 lanes in Pipe 1 match cipherlo
    vpcmpeqd    k1, C1, [work_C_0]
    kmovw       eax, k1
    and         eax, 0xFF
    jnz         .checkKey1Hi

.checkKey2:
    vpcmpeqd    k2, C2, [work_C_0]
    kmovw       eax, k2
    and         eax, 0xFF
    jnz         .checkKey2Hi

.checkKey3:
    vpcmpeqd    k3, C3, [work_C_0]
    kmovw       eax, k3
    and         eax, 0xFF
    jnz         .checkKey3Hi

.checkKey4:
    vpcmpeqd    k4, C4, [work_C_0]
    kmovw       eax, k4
    and         eax, 0xFF
    jnz         .checkKey4Hi

.nextKey:
    dec     r10d
    jz      .finished_Found_nothing

    add     r13b, 32
    movzx   L0hi, r13b
    mov     [RC5_72UnitWork_L0hi], L0hi
    jnc     .key_setup_1_inner_loop

    bswap   L0mid
    adc     L0mid, 0
    bswap   L0mid
    mov     eax, [work_pre_S1]
    jnc     .key_setup_1_mid_loop

    bswap   L0lo
    adc     L0lo, 0
    bswap   L0lo
    jmp     .key_setup_1_outer_loop

.checkKey1Hi:
    ; Pipe 1 matched cipherlo! 
    ; Now compute final round second half (D) and test against cipherhi.
    ; S[25] was intentionally deferred until now
    kmovw   eax, k1
    and     eax, 0xFF
    popcnt  edx, eax
    add     dword [RC5_72UnitWork_CMCcount], edx
    bsr     ebx, eax
    add     ebx, L0hi
    mov     [RC5_72UnitWork_CMChi], ebx
    mov     [RC5_72UnitWork_CMCmid], L0mid
    mov     [RC5_72UnitWork_CMClo], L0lo

    ; Compute deferred final subkey: S[25] = (S[25] + A + B) <<< 3
    vpaddd  A1, A1, S1(25)
    vpaddd  A1, A1, B1_1
    vprold  A1, A1, 3

    ; Complete Round high word: D = ((D ^ C) <<< C) + S[25]
    vpxord  D1, D1, C1
    vprolvd D1, D1, C1
    vpaddd  D1, D1, A1

    ; Compare with cipherhi into scratch mask k5, then cross-verify lane match
    vpcmpeqd    k5, D1, [work_C_1]
    kandw       k1, k1, k5               ; k1 = (matched low) AND (matched high) in same lane
    kmovw       eax, k1
    and         eax, 0xFF
    jz          .checkKey2               ; False half-match: check remaining pipes
    jmp         .saveFoundKey

.checkKey2Hi:
    kmovw   eax, k2
    and     eax, 0xFF
    popcnt  edx, eax
    add     dword [RC5_72UnitWork_CMCcount], edx
    bsr     ebx, eax
    add     ebx, 8
    add     ebx, L0hi
    mov     [RC5_72UnitWork_CMChi], ebx
    mov     [RC5_72UnitWork_CMCmid], L0mid
    mov     [RC5_72UnitWork_CMClo], L0lo

    ; Compute deferred final subkey for Pipe 2
    vpaddd  A2, A2, S2(25)
    vpaddd  A2, A2, B2_1
    vprold  A2, A2, 3

    ; Complete Round high word
    vpxord  D2, D2, C2
    vprolvd D2, D2, C2
    vpaddd  D2, D2, A2

    ; Cross-verify lane match
    vpcmpeqd    k5, D2, [work_C_1]
    kandw       k2, k2, k5               ; k2 = (matched low) AND (matched high) in same lane
    kmovw       eax, k2
    and         eax, 0xFF
    jz          .checkKey3
    shl         eax, 8                   ; Pipe 2 maps to key indices 8-15
    jmp         .saveFoundKey

.checkKey3Hi:
    kmovw   eax, k3
    and     eax, 0xFF
    popcnt  edx, eax
    add     dword [RC5_72UnitWork_CMCcount], edx
    bsr     ebx, eax
    add     ebx, 16
    add     ebx, L0hi
    mov     [RC5_72UnitWork_CMChi], ebx
    mov     [RC5_72UnitWork_CMCmid], L0mid
    mov     [RC5_72UnitWork_CMClo], L0lo

    ; Compute deferred final subkey for Pipe 3
    vpaddd  A3, A3, S3(25)
    vpaddd  A3, A3, B3_1
    vprold  A3, A3, 3

    ; Complete Round high word
    vpxord  D3, D3, C3
    vprolvd D3, D3, C3
    vpaddd  D3, D3, A3

    ; Cross-verify lane match
    vpcmpeqd    k5, D3, [work_C_1]
    kandw       k3, k3, k5               ; k3 = (matched low) AND (matched high) in same lane
    kmovw       eax, k3
    and         eax, 0xFF
    jz          .checkKey4
    shl         eax, 16                  ; Pipe 3 maps to key indices 16-23
    jmp         .saveFoundKey

.checkKey4Hi:
    kmovw   eax, k4
    and     eax, 0xFF
    popcnt  edx, eax
    add     dword [RC5_72UnitWork_CMCcount], edx
    bsr     ebx, eax
    add     ebx, 24
    add     ebx, L0hi
    mov     [RC5_72UnitWork_CMChi], ebx
    mov     [RC5_72UnitWork_CMCmid], L0mid
    mov     [RC5_72UnitWork_CMClo], L0lo

    ; Compute deferred final subkey for Pipe 4
    vpaddd  A4, A4, S4(25)
    vpaddd  A4, A4, B4_1
    vprold  A4, A4, 3

    ; Complete Round 12 high word
    vpxord  D4, D4, C4
    vprolvd D4, D4, C4
    vpaddd  D4, D4, A4

    ; Cross-verify lane match
    vpcmpeqd    k5, D4, [work_C_1]
    kandw       k4, k4, k5               ; k4 = (matched low) AND (matched high) in same lane
    kmovw       eax, k4
    and         eax, 0xFF
    jz          .nextKey                 ; False match on final pipe: advance to next key
    shl         eax, 24                  ; Pipe 4 maps to key indices 24-31

.saveFoundKey:
    ; WINNING KEY FOUND!
    bsf     eax, eax                 ; eax = key index in current batch (0..31)

    ; Record CMChi for the winning key
    mov     ebx, eax
    add     ebx, L0hi
    mov     [RC5_72UnitWork_CMChi], ebx

    ; Calculate exact completed iterations:
    ; completed_batches = (initial_iterations >> 5) - r10d
    ; total_keys_done   = (completed_batches * 32) + eax
    mov     edx, [rsi]               ; edx = initial iterations requested
    shr     edx, 5                   ; edx = initial batches requested
    sub     edx, r10d                ; edx = batches completed before current batch
    shl     edx, 5                   ; edx = keys completed before current batch
    add     edx, eax                 ; edx = total keys completed
    mov     [rsi], edx               ; *iterations = exact key index completed

    mov     [RC5_72UnitWork_L0mid], L0mid
    mov     [RC5_72UnitWork_L0lo], L0lo
    mov     eax, RESULT_FOUND
    jmp     .finished

.finished_Found_nothing:
    add     r13b, 32
    movzx   L0hi, r13b
    mov     [RC5_72UnitWork_L0hi], L0hi

    bswap   L0mid
    bswap   L0lo
    adc     L0mid, 0
    adc     L0lo, 0
    bswap   L0mid
    bswap   L0lo
    mov     [RC5_72UnitWork_L0mid], L0mid
    mov     [RC5_72UnitWork_L0lo], L0lo
    mov     eax, RESULT_NOTHING

.finished:

%ifdef _WINDOWS
    vmovdqa xmm6, [save_xmm6]
    vmovdqa xmm7, [save_xmm7]
    vmovdqa xmm8, [save_xmm8]
    vmovdqa xmm9, [save_xmm9]
    vmovdqa xmm10, [save_xmm10]
    vmovdqa xmm11, [save_xmm11]
    vmovdqa xmm12, [save_xmm12]
    vmovdqa xmm13, [save_xmm13]
    vmovdqa xmm14, [save_xmm14]
    vmovdqa xmm15, [save_xmm15]
    mov     rsi, [save_rsi]
    mov     rdi, [save_rdi]
%endif
    mov     rbx, [save_rbx]
    mov     rbp, [save_rbp]
    mov     r12, [save_r12]
    mov     r13, [save_r13]
    mov     r14, [save_r14]
    mov     r15, [save_r15]

    add     rsp, work_size

    vzeroupper
    ret

section .rodata
align 64
.I1:    dd  0,  1,  2,  3,  4,  5,  6,  7
.I2:    dd  8,  9, 10, 11, 12, 13, 14, 15
.I3:    dd 16, 17, 18, 19, 20, 21, 22, 23
.I4:    dd 24, 25, 26, 27, 28, 29, 30, 31
.IS3:   times 32 dd 0x9287BE8E
.IS4:   times 32 dd 0x30BF3847
.IS5:   times 32 dd 0xCEF6B200
.IS6:   times 32 dd 0x6D2E2BB9
.IS7:   times 32 dd 0x0B65A572
.IS8:   times 32 dd 0xA99D1F2B
.IS9:   times 32 dd 0x47D498E4
.IS10:  times 32 dd 0xE60C129D
.IS11:  times 32 dd 0x84438C56
.IS12:  times 32 dd 0x227B060F
.IS13:  times 32 dd 0xC0B27FC8
.IS14:  times 32 dd 0x5EE9F981
.IS15:  times 32 dd 0xFD21733A
.IS16:  times 32 dd 0x9B58ECF3
.IS17:  times 32 dd 0x399066AC
.IS18:  times 32 dd 0xD7C7E065
.IS19:  times 32 dd 0x75FF5A1E
.IS20:  times 32 dd 0x1436D3D7
.IS21:  times 32 dd 0xB26E4D90
.IS22:  times 32 dd 0x50A5C749
.IS23:  times 32 dd 0xEEDD4102
.IS24:  times 32 dd 0x8D14BABB
.IS25:  times 32 dd 0x2B4C3474
.IS0:   times 32 dd 0xBF0A8B1D

%ifidn __OUTPUT_FORMAT__, elf64
section .note.GNU-stack noalloc noexec nowrite progbits
%endif
