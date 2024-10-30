#!/usr/bin/env nextflow
nextflow.enable.dsl=2

// Define paths and parameters
params.inputDir = "/home/mzaz021/BIDSProject/sourcecode/IRTG01"
params.bidsDir = "/home/mzaz021/BIDSProject/combinedOutput/bids_output"
params.inputDirValidationLog= "/home/mzaz021/BIDSProject/combinedOutput/bids_output"
params.outputDir = "/home/mzaz021/BIDSProject/combinedOutput"
params.configFile = "/home/mzaz021/BIDSProject/code/configPHASEDIFF_B0identifier.json"
params.containerPath_dcm2bids = "/home/mzaz021/dcm2bids_3.2.0.sif"
params.singularity_image = "/home/mzaz021/validator_latest.sif"
params.containerPath_pydeface = "/home/mzaz021/pydeface_latest.sif"
params.containerPath_mriqc = "/home/mzaz021/mriqc_24.0.2.sif"
params.containerPath_fmriprep = "/home/mzaz021/fmriprep_latest.sif"
params.FS_LICENSE = '/home/mzaz021/freesurfer/license.txt'  
params.datasetDescription = "/home/mzaz021/dataset_description.json"
params.bidsValidatorLogs = "${params.outputDir}/bidsValidatorLogs"
params.defacedOutputDir = "${params.outputDir}/defaced"
params.mriqcOutputDir = "${params.outputDir}/mriQC"
params.fmriprepOutputDir = "${params.outputDir}/fmriprep"
params.workdir = '/home/mzaz021/BIDSProject/work'
params.participantList = ['001004', '001002']  // List of participants (without "sub-")

// Convert DICOM to BIDS
process ConvertDicomToBIDS {
    tag { "Participant: ${participantID}, Session: ${session_id}" }
    publishDir "${params.bidsDir}", mode: 'copy'
   
    input:
    tuple val(participantID), val(session_id), path(dicomDir)
   
    output:
    path "bids_output/**", emit: bids_files
   
    script:
    """
    mkdir -p bids_output
    apptainer run -e --containall \\
    -B ${dicomDir}:/dicoms:ro \\
    -B ${params.configFile}:/config.json:ro \\
    -B ./bids_output:/bids \\
    ${params.containerPath_dcm2bids} \\
    --session ${session_id} \\
    -o /bids \\
    -d /dicoms \\
    -c /config.json \\
    -p ${participantID} 
    """
}

process ValidateBIDS {

    input:
    val trigger  // ورودی برای تضمین اجرا پس از اتمام ConvertDicomToBIDS

    output:
    path "validation_log.txt", emit: logs

    errorStrategy 'ignore'

    script:
    """
    mkdir -p ${params.bidsValidatorLogs}
    echo "در حال اجرای اعتبارسنجی BIDS..."

    singularity run --cleanenv \
        ${params.singularity_image} \
        ${params.inputDirValidationLog} \
        --verbose 2>&1 | tee ${params.bidsValidatorLogs}/validation_log.txt

    echo "گزارش اعتبارسنجی در مسیر ${params.bidsValidatorLogs}/validation_log.txt ذخیره شد"
    """
}


// PyDeface process
process PyDeface {
    tag { niiFile.name }
    publishDir "${params.defacedOutputDir}", mode: 'copy'
   
    input:
    path niiFile
   
    output:
    path "defaced_${niiFile.simpleName}.nii.gz", emit: defaced_nii
   
    shell:
    '''
    input_file="!{niiFile.getName()}"
    output_file="defaced_!{niiFile.simpleName}.nii.gz"
    input_dir="$(dirname '!{niiFile}')"
    singularity_img="!{params.containerPath_pydeface}"
   
    apptainer run --bind "${input_dir}:/input" \\
    "${singularity_img}" \\
    pydeface /input/"${input_file}" --outfile "${output_file}"
    '''
}


// Copy dataset_description.json
process CopyDatasetDescription {
    input:
    tuple path(bidsDir), path(datasetDescription)
   
    output:
    path "${bidsDir}/bids_output"
   
    script:
    """
    mkdir -p ${bidsDir}/bids_output
    cp ${datasetDescription} ${bidsDir}/bids_output/dataset_description.json
    """
}


// Copy dataset_description.json to BIDS directory root
process CopyDatasetDescriptionRoot {
    input:
    tuple path(bidsDir), path(datasetDescription)
   
    output:
    path "${bidsDir}"
   
    script:
    """
    mkdir -p ${bidsDir}
    cp ${datasetDescription} ${bidsDir}/dataset_description.json
    """
}
// Run MRIQC process
process runMRIQC {
    container "${params.containerPath_mriqc}"
    cpus 4
    memory '8 GB'
    errorStrategy 'ignore' // Continue even if MRIQC fails
    maxRetries 2
    tag { "Participant: ${participant}" }
    publishDir "${params.mriqcOutputDir}/sub-${participant}", mode: 'copy', overwrite: true
   
    input:
    val participant
   
    output:
    path "reports/*.html", emit: 'reports'
    path "metrics/*.json", emit: 'metrics'
    path "figures/*", emit: 'figures'
   
    script:
    """
    mkdir -p ${params.mriqcOutputDir}/sub-${participant}
   
    export SINGULARITY_BINDPATH="${params.bidsDir}/bids_output,${params.mriqcOutputDir},${params.workdir}"
   
    apptainer exec --bind ${params.bidsDir}/bids_output:/bidsdir \\
    --bind ${params.mriqcOutputDir}:/outdir \\
    --bind ${params.workdir}:/workdir \\
    ${params.containerPath_mriqc} \\
    mriqc /bidsdir /outdir participant \\
    --participant_label ${participant} \\
    --nprocs ${task.cpus} \\
    --omp-nthreads ${task.cpus} \\
    --mem_gb 8 \\
    --no-sub \\
    -vvv \\
    --verbose-reports \\
    --work-dir /workdir > ${params.mriqcOutputDir}/sub-${participant}/mriqc_log_${participant}.txt 2>&1
   
    if [ \$? -ne 0 ]; then
        echo "MRIQC crashed for participant ${participant}" >> ${params.mriqcOutputDir}/mriqc_crash_log.txt
    fi
    """
}


// fMRIPrep process
process runFmriprep {
   

    input:
    val participantID

    script:
    """
    singularity run --cleanenv \
      --bind ${params.workdir}:/home/mzaz021/work \
      ${params.containerPath_fmriprep} \
      ${params.bidsDir} \
      ${params.fmriprepOutputDir} \
      participant \
      --participant-label ${participantID} \
      --fs-license-file ${params.FS_LICENSE} \
      --skip_bids_validation \
      --omp-nthreads 1 \
      --random-seed 13 \
      --skull-strip-fixed-seed
    """
}


// Workflow
// Workflow
workflow {

    // ایجاد یک کانال برای دایرکتوری‌ها
    dicomDirChannel = Channel
        .fromPath("${params.inputDir}/*", type: 'dir')
        .map { dir ->
            def folderName = dir.name
            def match = (folderName =~ /IRTG\d+_(\d+)(_S\d+)?_b\d+/)

            if (match) {
                def participantID = match[0][1]
                def session_id = match[0][2] ? match[0][2].replace('_S', 'ses-') : "ses-01"

                if (params.participantList.contains(participantID)) {
                    println "Processing participant: $participantID, session: $session_id"
                    return tuple(participantID, session_id, file(dir))
                }
            }
            return null
        }
        .filter { it != null }

    // گام ۱: تبدیل DICOM به BIDS
    bidsFiles = dicomDirChannel | ConvertDicomToBIDS
    // جمع‌آوری خروجی‌های ConvertDicomToBIDS برای اطمینان از اتمام کامل
    completed = bidsFiles.collect()

    // ایجاد یک تریگر برای شروع ValidateBIDS پس از اتمام ConvertDicomToBIDS
    completed.map { true } | ValidateBIDS

    // پردازش فایل‌های ۳D NIfTI
    niiFiles = bidsFiles.flatMap { it }.filter { it.name.endsWith(".nii.gz") }
    anatFiles = niiFiles.filter { it.toString().contains("/anat/") && "fslval ${it} dim4".execute().text.trim() == "1" }
    defacedFiles = anatFiles | PyDeface

    // مرحله ۳: کپی dataset_description.json به ریشه BIDS و زیردایرکتوری bids_output
    bidsDirChannel = bidsFiles.map { file(params.bidsDir) }
    descriptionChannel = Channel.of(file(params.datasetDescription))

    // کپی به bids_output
    bidsDirChannel
        .combine(descriptionChannel)
        | CopyDatasetDescription

    // کپی به دایرکتوری ریشه BIDS
    bidsDirChannel
        .combine(descriptionChannel)
        | CopyDatasetDescriptionRoot


    // مرحله ۴: اجرای MRIQC بر روی فایل‌های BIDS پس از کپی dataset_description.json
    bidsFiles
        .map { bidsFile ->
            def participantID = (bidsFile.name =~ /sub-(\d+)/)[0][1]
            return participantID
        }
        .distinct()  // جلوگیری از پردازش چند باره‌ی یک شرکت‌کننده
        | runMRIQC


    // مرحله ۵: اجرای fMRIPrep پس از MRIQC و حذف شناسایی، با وابستگی به CopyDatasetDescriptionRoot
    bidsFiles
        .map { bidsFile ->
            def participantID = (bidsFile.name =~ /sub-(\d+)/)[0][1]
            return participantID
        }
        .distinct()  // جلوگیری از پردازش چند باره‌ی یک شرکت‌کننده
        | runFmriprep
}

