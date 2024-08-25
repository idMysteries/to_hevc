[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Initialize variables for tracking space savings
$totalSpaceSavedMB = 0

# Determine files to process based on input arguments
if ($args.Count -eq 0) {
    # No arguments passed, process all video files in the current directory
    $filesToProcess = Get-ChildItem -File
} else {
    # Arguments passed, process specific files
    try {
        $filesToProcess = Get-Item -Path $args
    } catch {
        Write-Host "Error: One or more files do not exist or cannot be accessed." -ForegroundColor Red
        exit
    }
}

foreach ($file in $filesToProcess) {
    # Use ffprobe to check if the file contains a video stream
    $hasVideoStream = ffprobe -v quiet -select_streams v -show_entries stream=codec_type -of csv=p=0 $file.FullName

    # Proceed only if the file contains a video stream
    if ($hasVideoStream -match "video") {
        # Check the number of video streams in the file
        $videoStreamCount = (ffprobe -v quiet -select_streams v -show_entries stream=index -of csv=p=0 $file.FullName).Length
        if ($videoStreamCount -gt 1) {
            Write-Host "Skipping file: $($file.Name) because it has more than one video stream." -ForegroundColor Yellow
            continue
        }

        # Retrieve the codec information for the video stream using ffprobe
        $codecInfo = ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $file.FullName

        # Check if the video codec is not HEVC, VP9, AV1
        if ($codecInfo -notmatch "hevc|vp9|av01") {
            Write-Host "Converting file: $($file.Name)" -ForegroundColor Green

            # Retrieve the bitrate of the video stream (not the entire file)
            $videoBitrateInfo = ffprobe -v quiet -select_streams v:0 -show_entries stream=bit_rate -of default=nk=1:nw=1 $file.FullName
            $videoBitrate = [int]($videoBitrateInfo -replace "\D")

            # If the bitrate is not provided, calculate it based on file size and duration
            if ($videoBitrate -eq 0) {
                Write-Host "Video bitrate not found, using overall file bitrate." -ForegroundColor Yellow
                $videoBitrateInfo = ffprobe -v quiet -show_entries format=bit_rate -of default=nk=1:nw=1 $file.FullName
                $videoBitrate = [int]($videoBitrateInfo -replace "\D")
            }

            # Ensure the bitrate is valid and greater than zero
            if ($videoBitrate -gt 0) {
                # Calculate the new bitrate (60% of the original)
                $newBitrate = [int]($videoBitrate * 0.6)

                # Define the output file path
                $outputFile = "$($file.DirectoryName)\$($file.BaseName)_HEVC$($file.Extension)"

                # Perform the video conversion using ffmpeg
                $ffmpegResult = ffmpeg -i $file.FullName -c:v hevc_amf -quality quality -b:v "$($newBitrate)" -c:a copy -c:s copy -hide_banner $outputFile

                # Check if the conversion was successful by verifying the presence of the output file
                if (Test-Path $outputFile) {
                    Write-Host "Conversion completed: $outputFile" -ForegroundColor Green

                    # Calculate the space savings
                    $originalSizeMB = [math]::Round(($file.Length / 1MB), 2)
                    $outputFileInfo = Get-Item $outputFile
                    $outputSizeMB = [math]::Round(($outputFileInfo.Length / 1MB), 2)
                    $spaceSavedMB = [math]::Round(($originalSizeMB - $outputSizeMB), 2)

                    if ($outputSizeMB -gt 0) {
                        Write-Host "Original Size: $originalSizeMB MB, Converted Size: $outputSizeMB MB, Space Saved: $spaceSavedMB MB" -ForegroundColor Cyan
                        $totalSpaceSavedMB += $spaceSavedMB

                        # Check the integrity of the output file (e.g., duration, size) before deletion
                        $outputBitrateInfo = ffprobe -v quiet -show_entries format=bit_rate -of default=nk=1:nw=1 $outputFile
                        $outputBitrate = [int]($outputBitrateInfo -replace "\D")

                        if ($outputBitrate -gt 0) {
                            # Delete the original file only if the conversion succeeded and the output is valid
                            Remove-Item $file.FullName -Force
                            Write-Host "Original file deleted: $($file.Name)" -ForegroundColor Green
                        } else {
                            Write-Host "Warning: Output file has invalid bitrate, keeping the original file: $($file.Name)" -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host "Error: Conversion failed, keeping the original file: $($file.Name)" -ForegroundColor Red
                    }
                } else {
                    Write-Host "Error: Conversion failed, keeping the original file: $($file.Name)" -ForegroundColor Red
                }
            } else {
                Write-Host "Warning: Invalid video bitrate detected, skipping file: $($file.Name)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "Skipping file (already HEVC, VP9, or AV1): $($file.Name)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Skipping non-video file: $($file.Name)" -ForegroundColor Yellow
    }
}

# Display the total space saved after processing all files
$roundedTotalSpaceSavedMB = [math]::Round($totalSpaceSavedMB, 2)
Write-Host "Total space saved: $roundedTotalSpaceSavedMB MB" -ForegroundColor Green
Write-Host "All files processed." -ForegroundColor Green