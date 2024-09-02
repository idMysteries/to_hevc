[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (!(Get-Command ffmpeg -ErrorAction SilentlyContinue) -or !(Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Host "Error: ffmpeg or ffprobe not found. Please install them and add to PATH." -ForegroundColor Red
    exit
}

$gpu = ""

$videoControllers = Get-WmiObject Win32_VideoController

foreach ($controller in $videoControllers) {
    if ($controller.Name -like "*NVIDIA*") {
        $gpu = "NVIDIA"
        break
    } elseif ($controller.Name -like "*AMD*") {
        $gpu = "AMD"
    } elseif ($controller.Name -like "*Intel*") {
        $gpu = "Intel"
    }
}

if ($gpu -eq "NVIDIA") {
    $encoder = @("hevc_nvenc")
} elseif ($gpu -eq "AMD") {
    $encoder = @("hevc_amf", "-quality", "quality", "-rc", "qvbr", "-qvbr_quality_level", "33", "-vbaq", "1", "-pa_lookahead_buffer_depth", "40", "-pa_caq_strength", "high")
} elseif ($gpu -eq "Intel") {
    $encoder = @("hevc_qsv")
} else {
    $encoder = @("libx265")
}

# Initialize variables for tracking space savings and processed file count
$totalSpaceSavedMB = 0
$processedFilesCount = 0

$imageExtensions = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.webp')

$filesToProcess = if ($args.Count -eq 0) {
    Get-ChildItem -File | Where-Object { $imageExtensions -notcontains $_.Extension.ToLower() }
} else {
    try {
        $files = Get-Item -Path $args
        $files | Where-Object { $imageExtensions -notcontains $_.Extension.ToLower() }
    } catch {
        Write-Host "Error: One or more files do not exist or cannot be accessed." -ForegroundColor Red
        exit
    }
}

foreach ($file in $filesToProcess) {
    # Use ffprobe to check if the file contains a video stream
    if ((ffprobe -v quiet -select_streams v -show_entries stream=codec_type -of csv=p=0 $file.FullName) -notmatch "video") {
        Write-Host "Skipping non-video file: $($file.Name)" -ForegroundColor Yellow
        continue
    }

    # Check the number of video streams in the file
    $videoStreamIndexes = (ffprobe -v quiet -select_streams v -show_entries stream=index -of csv=p=0 $file.FullName).TrimEnd(',').Split(",")
    if ($videoStreamIndexes.Count -gt 1) {
        Write-Host "Skipping file: $($file.Name) because it has more than one video stream." -ForegroundColor Yellow
        continue
    }

    # Retrieve the codec information for the video stream using ffprobe
    $codecInfo = ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $file.FullName

    # Check if the video codec is not HEVC, VP9, AV1
    if ($codecInfo -match "hevc|vp9|av01") {
        Write-Host "Skipping file (already HEVC, VP9, or AV1): $($file.Name)" -ForegroundColor Yellow
        continue
    }

    Write-Host "Converting file: $($file.Name)" -ForegroundColor Green

    # Retrieve the bitrate of the video stream (not the entire file)
    $videoBitrateInfo = ffprobe -v quiet -select_streams v:0 -show_entries stream=bit_rate -of default=nk=1:nw=1 $file.FullName
    $videoBitrate = 0

    # Check if the bitrate info is empty or null
    if ([string]::IsNullOrWhiteSpace($videoBitrateInfo)) {
        Write-Host "Video bitrate not found, using overall file bitrate." -ForegroundColor Yellow
        $videoBitrateInfo = ffprobe -v quiet -show_entries format=bit_rate -of default=nk=1:nw=1 $file.FullName
    }

    # Check if the bitrate info is still empty or null
    if ([string]::IsNullOrWhiteSpace($videoBitrateInfo)) {
        Write-Host "Warning: Unable to determine bitrate, skipping file: $($file.Name)" -ForegroundColor Yellow
        continue
    }

    # Try to parse the bitrate as an integer
    if ([int]::TryParse(($videoBitrateInfo -replace "\D"), [ref]$videoBitrate)) {
        # Ensure the bitrate is valid and greater than zero
        if ($videoBitrate -le 0) {
            Write-Host "Warning: Invalid video bitrate detected, skipping file: $($file.Name)" -ForegroundColor Yellow
            continue
        }
    } else {
        Write-Host "Warning: Unable to parse bitrate, skipping file: $($file.Name)" -ForegroundColor Yellow
        continue
    }

    # Calculate the new bitrate (60% of the original)
    $newBitrate = [int]($videoBitrate * 0.6)

    # Define the output file path
    $outputFile = "$($file.DirectoryName)\$($file.BaseName)_HEVC$($file.Extension)"

    # Perform the video conversion using ffmpeg
    if ($gpu -eq "AMD") {
        ffmpeg -y -i $file.FullName -c:v $encoder -c:a copy -c:s copy -c:d copy -hide_banner $outputFile
    } else {
        ffmpeg -y -i $file.FullName -c:v $encoder -b:v "$($newBitrate)" -c:a copy -c:s copy -c:d copy -hide_banner $outputFile
    }

    $originalDuration = ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $file.FullName
    $outputDuration = ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $outputFile
    if ([math]::Abs($originalDuration - $outputDuration) -gt 1) {
        Write-Host "Error: Output file duration mismatch, keeping the original file: $($file.Name)" -ForegroundColor Red
        Remove-Item $outputFile -Force
        continue
    }

    Write-Host "Conversion completed: $outputFile" -ForegroundColor Green

    # Calculate the space savings
    $originalSizeMB = [math]::Round(($file.Length / 1MB), 2)
    $outputFileInfo = Get-Item $outputFile
    $outputSizeMB = [math]::Round(($outputFileInfo.Length / 1MB), 2)
    $spaceSavedMB = [math]::Round(($originalSizeMB - $outputSizeMB), 2)

    Write-Host "Original Size: $originalSizeMB MB, Converted Size: $outputSizeMB MB, Space Saved: $spaceSavedMB MB" -ForegroundColor Cyan
    $totalSpaceSavedMB += $spaceSavedMB
    $processedFilesCount++

    $roundedTotalSpaceSavedMB = [math]::Round($totalSpaceSavedMB, 2)
    Write-Host "Total space saved: $roundedTotalSpaceSavedMB MB (Processed files: $processedFilesCount)" -ForegroundColor Cyan

    # Check the integrity of the output file (e.g., duration, size) before deletion
    $outputBitrateInfo = ffprobe -v quiet -show_entries format=bit_rate -of default=nk=1:nw=1 $outputFile
    $outputBitrate = [int]($outputBitrateInfo -replace "\D")

    Remove-Item $file.FullName -Force    
}

Write-Host "All files processed." -ForegroundColor Green
