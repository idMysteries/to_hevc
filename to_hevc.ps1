param (
    [int]$qp = 23,  # Default value for qp
    [string[]]$files = @(),  # Array to hold file paths
    [switch]$Save  # Parameter to save original files
)

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
    $encoder = @("hevc_amf", "-quality", "quality", "-qp_i", $qp, "-qp_p", $($qp+2))
} elseif ($gpu -eq "Intel") {
    $encoder = @("hevc_qsv")
} else {
    $encoder = @("libx265", "-x265-params", "crf=$($qp):ref=6", "-pix_fmt", "yuv420p10le")
}

# Initialize variables for tracking space savings and processed file count
$totalSpaceSavedMB = 0
$processedFilesCount = 0

# Define a list of extensions to filter out (image, audio, text, and subtitle files)
$excludedExtensions = @(
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.webp',          # Image files
    '.mp3', '.wav', '.flac', '.aac', '.ogg', '.wma', '.m4a', '.mka',    # Audio files
    '.txt', '.doc', '.docx', '.pdf', '.rtf', '.odt',                    # Text files
    '.srt', '.sub', '.ass', '.vtt'                                      # Subtitle files
)

$filesToProcess = if ($files.Count -eq 0) {
    Get-ChildItem -File | Where-Object { $excludedExtensions -notcontains $_.Extension.ToLower() }
} else {
    try {
        $fileItems = Get-Item -LiteralPath $files
        $fileItems | Where-Object { $excludedExtensions -notcontains $_.Extension.ToLower() }
    } catch {
        Write-Host "Error: One or more files do not exist or cannot be accessed." -ForegroundColor Red
        exit
    }
}

foreach ($file in $filesToProcess) {
    # Use ffprobe to check if the file contains a video stream
    $videoStreamCheck = ffprobe -v quiet -select_streams v -show_entries stream=codec_type -of csv=p=0 $file.FullName
    if (-not $videoStreamCheck -or $videoStreamCheck -notmatch "video") {
        Write-Host "Skipping non-video file: $($file.Name)" -ForegroundColor Yellow
        continue
    }

    # Check the number of video streams in the file
    $videoStreamIndexes = ffprobe -v quiet -select_streams v -show_entries stream=index -of csv=p=0 $file.FullName
    if (-not $videoStreamIndexes) {
        Write-Host "Skipping file: $($file.Name) due to no video streams found." -ForegroundColor Yellow
        continue
    }

    $videoStreamIndexesArray = $videoStreamIndexes.TrimEnd(',').Split(",")
    if ($videoStreamIndexesArray.Count -gt 1) {
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

    # Define the temporary output file path
    $outputFile = "$($file.DirectoryName)\$($file.BaseName)_HEVC$($file.Extension)"

    # Perform the video conversion using ffmpeg
    ffmpeg -y -i $file.FullName -c:v $encoder -c:a copy -c:s copy -c:d copy -map 0 -hide_banner $outputFile

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
    $outputFileInfo = Get-Item -LiteralPath $outputFile
    $outputSizeMB = [math]::Round(($outputFileInfo.Length / 1MB), 2)
    $spaceSavedMB = [math]::Round(($originalSizeMB - $outputSizeMB), 2)

    Write-Host "Original Size: $originalSizeMB MB, Converted Size: $outputSizeMB MB, Space Saved: $spaceSavedMB MB" -ForegroundColor Cyan
    $totalSpaceSavedMB += $spaceSavedMB
    $processedFilesCount++

    $roundedTotalSpaceSavedMB = [math]::Round($totalSpaceSavedMB, 2)
    Write-Host "Total space saved: $roundedTotalSpaceSavedMB MB (Processed files: $processedFilesCount)" -ForegroundColor Cyan

    # Remove the original file unless the -Save switch is specified
    if (-not $Save) {
        Remove-Item -LiteralPath $file.FullName -Force
        Rename-Item -LiteralPath $outputFile -NewName $file.Name
    }
}

Write-Host "All files processed." -ForegroundColor Green
