#!/usr/bin/env python3
import sys
import base64
import re

def encode_distributed_net_kernel(data: bytes) -> str:
    """
    Compresses data using the custom distributed.net run-length/Lz variant
    and returns a Base64 encoded string.
    """
    out = bytearray()
    i = 0
    n = len(data)
    
    while i < n:
        best_len = 0
        best_off = 0
        window_start = max(0, i - 65535)
        max_match_len = min(127, n - i)
        
        if max_match_len >= 3:
            for j in range(window_start, i):
                match_len = 0
                while match_len < max_match_len and data[j + match_len] == data[i + match_len]:
                    match_len += 1
                if match_len > best_len:
                    best_len = match_len
                    best_off = i - j
                    
        if best_len >= 3:
            out.append(0x80 | best_len)
            out.append(best_off & 0xFF)
            out.append((best_off >> 8) & 0xFF)
            i += best_len
        else:
            lit_run = []
            while i < n and len(lit_run) < 127:
                if n - i >= 3:
                    found_future_match = False
                    w_start = max(0, i - 65535)
                    for m in range(w_start, i):
                        if data[m:m+3] == data[i:i+3]:
                            found_future_match = True
                            break
                    if found_future_match and len(lit_run) > 0:
                        break
                lit_run.append(data[i])
                i += 1
            out.append(len(lit_run) & 0x7F)
            out.extend(lit_run)
            
    return base64.b64encode(out).decode('utf-8')

if __name__ == "__main__":
    # Ensure a file argument was passed via terminal
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <kernel_file.cl>", file=sys.stderr)
        sys.exit(1)
        
    try:
        # Read the modified OpenCL source file
        with open(sys.argv[1], 'rb') as f:
            content = f.read()
            
        # 1. Try to find //CORENAME= using a raw byte string (rb)
        corename_match = re.search(rb'//CORENAME=\s*([a-zA-Z0-9_]+)', content)
        if corename_match:
            corename = corename_match.group(1).decode('utf-8')
        else:
            # 2. Fallback to extracting the kernel function name using a raw byte string (rb)
            kernel_match = re.search(rb'__kernel\s+void\s+([a-zA-Z0-9_]+)', content)
            if kernel_match:
                # Append _src to match standard naming conventions
                corename = kernel_match.group(1).decode('utf-8') + "_src"
            else:
                # 3. Raise an error if parsing fails completely
                raise ValueError(f"Could not determine corename from '{sys.argv[1]}': Neither '//CORENAME=' nor '__kernel void' was found.")
            
        # Compress and encode into raw Base64 string
        raw_b64 = encode_distributed_net_kernel(content)
        
        # Split the raw string into clean, 70-character chunks
        chunk_size = 70
        chunks = [raw_b64[i:i+chunk_size] for i in range(0, len(raw_b64), chunk_size)]
        
        # Output the formatted C++ code structure dynamically using the resolved corename
        print(f'static const char {corename}[]=\n')
        for idx, chunk in enumerate(chunks):
            if idx == len(chunks) - 1:
                print(f'"{chunk}";')  # The final row gets the closing semicolon
            else:
                print(f'"{chunk}"')   # Intermediate rows keep clean quotes
                
    except Exception as e:
        print(f"Error processing file: {e}", file=sys.stderr)
        sys.exit(1)

