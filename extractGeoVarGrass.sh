 #!/bin/sh
echo "Batch import of geodata"


################################################################################
#
# Export a csv file with data extracted for geodata set :
# Agri, forest, caco3 and dem. 
# The output file will be formated with R in another script.
# At the time of writting those lines, the plugin spgrass 6 did not work 
# within a grass session, within tmux, using R through vim-r-plugin
#
# Usage :
# 1. open grass session with corresponding region (see crs parameters)
# 2. control path to db (pathDb) and path to source (pathSrc)
# 2. control that 
#
################################################################################

# if external output is enable, disable
v.external.out -r

# set path variables
pathData="../../data/"
pathDb=$pathData"dataBase/csv/"
pathSrc=$pathData"dataSource/"

 
#Set variable that will be used in multiple parts
pathInBassins=$pathSrc"bassins/"
pathOutRiverDb=$pathDb"riverGeomorphLanduse.csv"
subCatName="subCatchValais"
crs='EPSG:21781'
res=250

#set grass parameters and remove mask
g.region res=$res
r.mask -r


# Set boolean for importation
importBassins=1
importPointsCsv=1
polygonizeJoinBassin=1
exportVectorPostGis=1
exportRiverEnviro=1
importLanduse=1
importLanduseBau=1
importGeoMorpho=1

removeAll=0


# import from files, 
if [ "$importBassins" -ne 0 ]; then 
	extMap="asc"

	
	patTmp="importBassin"
	tmpName="$patTmp""Tmp"
	patTmpA="$patTmp""A"
	patTmpB="$patTmp""B"



	for i in $pathInBassins*.$extMap 
	do
		fnA=$patTmpA`basename "$i" ".$extMap" `;
		fnB=$patTmpB`basename "$i" ".$extMap" `;
		num=`echo "$fnA"| sed "s/[^0-9]*//g"`
		`r.in.gdal -e --o -o input="$i" output="$fnA" title="$fnA"`
		`r.null map="$fnA" setnull=0`
		`r.mapcalc --o "$fnB"="$fnA*$num"`
		if [ "$num" == "001" ]; then
			`r.mask raster="$fnB" maskcats=NULL`
			r.mapcalc --o "$subCatName"="$fnB"
		else
			r.mapcalc --o "$tmpName"=$subCatName
			`r.cross  --overwrite input="$tmpName","$fnB" output="$subCatName"`
		fi
		`g.remove rast="$fnA"`
		`g.remove rast="$fnB"`
	done
fi


# We should have a $subCatName map. We dont want any calculation outsite this map :
`r.mask "$subCatName"`


# import output sub-watershed point, clean columns and querry raster
if [ "$importPointsCsv" -ne 0 ]; then
	extPoints="csv"
	varTable=`ls "$pathInBassins"*."$extPoints"`
	cols="id int,x int,y int,id_orig varchar(10)"
	`v.in.ascii --o input=$varTable output=outputPoints columns="$cols" separator=";" skip=1 x=2 y=3 cat=1`
	`v.db.addcolumn  map=outputPoints columns='bassinCrossID INT'`
	#we update the new column with raster value. For each bassin, we know the corresponding raster value to make a join in the next step.
	`v.what.rast  map=outputPoints raster="$subCatName" column=bassinCrossID`
fi


# polygonize bassin raster map and join corresponding point by cat
if [ "$polygonizeJoinBassin" -ne 0 ]; then
	`r.to.vect -v --o --quiet input="$subCatName" output="$subCatName" type=area`
	`v.db.join map="$subCatName" column=cat otable=outputPoints ocolumn=bassinCrossID`
	`v.db.dropcolumn map="$subCatName" columns="label"`
	`v.db.renamecolumn map="$subCatName" column=id_orig,bassinName`
	`v.db.renamecolumn map="$subCatName" column=id,bassinID`
fi


if [ "$importGeoMorpho" -ne 0 ]; then
	# path to raster dir
	pathGeomorpho=$pathSrc"geoMorpho/"
	# loop inside directory to find tif files to import
		for f in $pathGeomorpho*.tif
		do 
			n=`basename $f | sed -e 's/\..*//'`
			r.in.gdal --o input=$f out=$n
		done
fi



if [ "$importLanduse" -ne 0 ]; then
	g.region res=100
	pathLanduse85=$pathSrc"landUse/landuse85-09/AREA_NOAS04_17_131004.csv"
	luPts="landUsePts"
	cols="X int,Y int,RELI int,GMDE int,FJ85 int,FJ97 int,FJ09 int,AS85R_17 int,
	AS97R_17 int,AS09_17 int,AS85R_4 int,AS97R_4 int,AS09_4 int"

	# import in ascii. see manual to import only selected column (use tr or awk)
	v.in.ascii -r --o input=$pathLanduse85 separator=";" skip=1 columns="$cols" x=1 y=2 cat=3 out=$luPts

	# set map name and sql to perform on landUsPts table
	lu="
	forest85;AS85R_4=3
	agri85;AS85R_4=2
	forest97;AS97R_4=3
	agri97;AS97R_4=2
	forest09;AS09_4=3
	agri09;AS09_4=2
	"
	for i in $lu
	do
		n=`echo $i|awk -F ";" '{print $1}'`
		s=`echo $i|awk -F ";" '{print $2}'`
		v.to.rast --o input=$luPts type=point use=val value=1 out=$n where="$s"
		r.neighbors -c --o input=$n out=$n"n" method=count size=5 # resol of 100 = radius of 250m
	done
	g.region res="$res"
fi


if [ "$importLanduseBau" -ne 0 ]; then 	
	g.region res=100
	# Busines as usual land cover 
	# set fonction to do a neighbors analysis
	luFn(){
		gdalwarp -of GTiff -overwrite -t_srs EPSG:21781 $1 $2
		r.in.gdal --o input=$2 out=$3
		r.mapcalc --o "$4 = if($3==1||$3==2||$3==3,1,null())"
		r.neighbors -c --o input=$4 out=$4"n" method=count size=5
		r.mapcalc --o  "$5 = if($3==4||$3==5||$3==6,1,null())"	
		r.neighbors -c --o input=$5 out=$5"n" method=count size=5
	}

	# 2009 
	luFrom="$pathSrc""landUse/lu2009/w001001.adf" #$1
	luTo="$pathSrc""landUse/lu2009/lu2009.tif" #$2
	luGr="landUseBau09" #$3
	luForest="forestBau09" #$4
	luAgri="agriBau09" #$5
	luFn $luFrom $luTo $luGr $luForest $luAgri
	
	# 2025 
	luFrom="$pathSrc""landUse/lu2025/w001001.adf" #$1
	luTo="$pathSrc""landUse/lu2025/lu2025.tif" #$2
	luGr="landUseBau25" #$3
	luForest="forestBau25" #$4
	luAgri="agriBau25" #$5
	luFn $luFrom $luTo $luGr $luForest $luAgri

	# 2045
	luFrom="$pathSrc""landUse/lu2045/w001001.adf" #$1
	luTo="$pathSrc""landUse/lu2045/lu2045.tif" #$2
	luGr="landUseBau45" #$3
	luForest="forestBau45" #$4
	luAgri="agriBau45" #$5
	luFn $luFrom $luTo $luGr $luForest $luAgri


	# 2050
	luFrom="$pathSrc""landUse/lu2050/w001001.adf" #$1
	luTo="$pathSrc""landUse/lu2050/lu2050.tif" #$2
	luGr="landUseBau50" #$3
	luForest="forestBau50" #$4
	luAgri="agriBau50" #$5
	luFn $luFrom $luTo $luGr $luForest $luAgri

	`g.region res="$res"` 
fi


if [ "$exportRiverEnviro" -ne 0 ]; then
	riv='river'
	rivRast='river250'
	rivPts='riverPts250'
	v.in.ogr --o dsn=$pathSrc"/stream/streamorder.shp" out=river
	v.to.rast --o input=$riv output=$rivRast use=val value=1
	r.to.vect --o input=$rivRast type=point output=$rivPts
	v.db.dropcolumn map=$rivPts columns=label,value
	v.db.addcolumn map=$rivPts columns='x INT,y INT,bassinID INT'
	v.to.db map=$rivPts option=coor columns=x,y
	v.what.vect map=$rivPts column=bassinID qmap="$subCatName" qcolumn=bassinID
	varList="
	dem;real
	slope;real
	caco3;int
	agri85n;int
	agri97n;int 
	agri09n;int
	agriBau09n;int
	agriBau25n;int
	agriBau45n;int
	agriBau50n;int
	forest85n;int
	forest97n;int
	forest09n;int 
	forestBau09n;int
	forestBau25n;int 
	forestBau45n;int 
	forestBau50n;int"

	for i in $varList
	do 
		n=`echo $i | awk -F ";" '{print $1}'`
		t=`echo $i | awk -F ";" '{print $2}'`
		v.db.addcolumn map=$rivPts columns=$n" $t"
		v.what.rast map=$rivPts raster=$n column=$n
	done
	rm $pathOutRiverDb
	# Create a tempFile that will be treated with R later
	db.out.ogr dsn=$pathOutRiverDb input=$rivPts format='CSV'
fi


# remove all data
if [ "$removeAll" -ne 0 ]; then
	g.remove rast=`g.mlist type=rast sep=','`
	g.remove vect=`g.mlist type=vect sep=','`
fi




