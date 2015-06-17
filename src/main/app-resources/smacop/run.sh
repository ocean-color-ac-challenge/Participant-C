#!/bin/bash

# source the ciop functions (e.g. ciop-log)
source ${ciop_job_include}

# define the exit codes
SUCCESS=0
ERR_NOINPUT=1
ERR_BEAM=2
ERR_NOPARAMS=5
ERR_JAVAVERSION=10

# add a trap to exit gracefully
function cleanExit ()
{
   local retval=$?
   local msg=""
   case "${retval}" in
     ${SUCCESS})      msg="Processing successfully concluded";;
     ${ERR_NOPARAMS}) msg="Expression not defined";;
     ${ERR_BEAM})    msg="Beam failed to process product $product (Java returned $res).";;
     ${ERR_JAVAVERSION})	msg="The version of the JVM must be at least 1.7";;
     *)             msg="Unknown error";;
   esac
   [ "${retval}" != "0" ] && ciop-log "ERROR" "Error ${retval} - ${msg}, processing aborted" || ciop-log "INFO" "${msg}"
   exit ${retval}
}
trap cleanExit EXIT

ciop-log "INFO" "Checking Java version"
${_CIOP_APPLICATION_PATH}/shared/bin/detect_java.sh || exit ${ERR_JAVAVERSION}

# create the output folder to store the output products
mkdir -p ${TMPDIR}/output
export OUTPUTDIR=${TMPDIR}/output
format="$( ciop-getparam format )"

[ "${format}" != "BEAM-DIMAP" ] && [ "${format}" != "GeoTIFF" ] && exit ${ERR_FORMAT}

aerosolType="$( ciop-getparam aerosolType )"
bandNames="$( ciop-getparam bandNames )"
invalidPixel="$( ciop-getparam invalidPixel )"
maskExpression="$( ciop-getparam maskExpression )"
surfPress="$( ciop-getparam surfPress )"
tauAero550="$( ciop-getparam tauAero550 )"
uH2o="$( ciop-getparam uH2o )"
uO3="$( ciop-getparam uO3 )"
useMerisADS="$( ciop-getparam useMerisADS )"

# Evaluation parameters
# get the POIs
echo -e "Name\tLatitude\tLongitude" > $TMPDIR/poi.csv
echo "$( ciop-getparam poi | tr ',' '\t' | tr '|' '\n' )" >> $TMPDIR/poi.csv
# get the window size
window="$( ciop-getparam window )"
# get the aggregation
aggregation="$( ciop-getparam aggregation )"

# set the processing flags
pixex="$( ciop-getparam pixex )"
publish_l2="$( ciop-getparam publishL2 )"

prd_counter=1

# loop and process all MERIS products
while read inputfile 
do
  # report activity in log
  ciop-log "INFO" "Retrieving input ${prd_counter} - ${inputfile} from storage"
  
  prd_ref="$( opensearch-client "${inputfile}" enclosure )"
  [ -z "${prd_ref}" ] && { 
    ciop-log "ERR" "Could not resolve ${inputfile}"
  } || {

    # retrieve the MERIS product product to the local temporary folder
    retrieved="$( echo ${prd_ref} | ciop-copy -o $TMPDIR - )"
  
    # check if the file was retrieved
    [ "$?" == "0" -a -e "${retrieved}" ] || exit ${ERR_NOINPUT}
  
    # report activity
    ciop-log "INFO" "Retrieved $( basename ${retrieved} ), moving on to smac operator"
	
    outputname="$( basename ${retrieved} )"
  
    ${_CIOP_APPLICATION_PATH}/shared/bin/gpt.sh SmacOp \
      -SsourceProduct=${retrieved} \
      -f ${format} \
      -t ${OUTPUTDIR}/${outputname} \
      -PaerosolType=${aerosolType} \
      -PbandNames="${bandNames}" \
      -PinvalidPixel=${invalidPixel} \
      -PmaskExpression="${maskExpression}" \
      -PsurfPress=${surfPress} \
      -PtauAero550=${tauAero550} \
      -PuH2o=${uH2o} \
      -PuO3=${uO3} \
      -PuseMerisADS=${useMerisADS} 
  
    res=$?
    [ ${res} != 0 ] && exit ${ERR_BEAM}

    run=${CIOP_WF_RUN_ID}
 
    [ "${pixex}" == "true" ] && {
      # invoke pixex
      l2b="$( basename ${OUTPUTDIR}/${outputname} )"
      prddate="${l2b:20:2}/${l2b:18:2}/${l2b:14:4}"
      ciop-log "INFO" "Apply BEAM PixEx Operator to ${l2b}"
      prd_orbit=$( echo ${l2b:49:5} | sed 's/^0*//' ) 

      # apply PixEx BEAM operator
      ${_CIOP_APPLICATION_PATH}/shared/bin/gpt.sh \
        -Pvariable=${outputname}.dim \
        -Pvariable_path=${OUTPUTDIR} \
        -Poutput_path=${OUTPUTDIR} \
        -Pprefix=${run} \
        -Pcoordinates=${TMPDIR}/poi.csv \
        -PwindowSize=${window} \
        -PaggregatorStrategyType="${aggregation}" \
        ${_CIOP_APPLICATION_PATH}/pixex/libexec/PixEx.xml 1>&2
  	
      res=$?
      [ ${res} != 0 ] && exit ${ERR_BEAM_PIXEX} 
 
      result="$( find ${OUTPUTDIR} -name "${run}*measurements.txt" )"
     
      [ -n "${result}" ] && {
      	skip_lines=$( cat ${result} | grep -n "ProdID" | cut -d ":" -f 1 )

      	cat "${result}" |  tail -n +${skip_lines} | tr "\t" "," | awk -f ${_CIOP_APPLICATION_PATH}/pixex/libexec/tidy.awk -v run=${run} -v date=${prddate} -v orbit=${prd_orbit} - > "${OUTPUTDIR}/${l2b}.txt"

      	ciop-log "INFO" "Publishing extracted pixel values"
      	ciop-publish -m "${OUTPUTDIR}/${l2b}.txt"
      	rm -f "${OUTPUTDIR}/${l2b}.txt"
      }
    }

    [ "${publish_l2}" == "true" ] && {
      # create RGB quicklook
      ${_CIOP_APPLICATION_PATH}/shared/bin/pconvert.sh \
          -f png \
          -p ${_CIOP_APPLICATION_PATH}/smacop/etc/profile.rgb \
          -o ${OUTPUTDIR} \
          ${OUTPUTDIR}/${outputname}.dim

      tar -C ${OUTPUTDIR} -cvzf ${TMPDIR}/${outputname}.tgz ${outputname}.dim ${outputname}.data
      ciop-log "INFO" "Publishing $outputname.tgz"
      ciop-publish -m ${TMPDIR}/${outputname}.tgz
      ciop-publish -m ${OUTPUTDIR}/${outputname}.png
      rm -fr ${OUTPUTDIR}/${outputname}.tgz
      rm -f ${OUTPUTDIR}/${outputname}.png
    }
    # cleanup
    rm -fr ${retrieved} ${OUTPUTDIR}/${outputname}.d* 
   
    prd_counter=$(( ${prd_counter} + 1 )) 
  }
done

exit 0

