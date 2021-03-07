module p3_cloud_optics
  ! Compute cloud optical properties (optical thickness in LW and SW, w0 and g in SW) 
  !   from particle size distributions coming from P3 microphysics scheme.
  !   
  ! Here, we use the RRTMG lookup tables for liquid and ice
  !   cloud properties, with the ice cloud properties used for all 
  !   categories of ice in the P3 microphysics.  If the size (Dge) 
  !   of ice exceeds the maximum value in the lookup table, the 
  !   extinction coefficient is scaled down by a factor Dge_tmax/Dge 
  !   where Dge_tmax is the maximum Dge in the lookup table.  In this 
  !   case, the forward-scattering-factor, single-scattering-albedo and
  !   asymmetry parameter are taken from the high end of the lookup table.
  !   This approach is based on conversations with Qiang Fu.
  !
  ! Note these values will be fed directly into RRTMG and will replace
  !   the cldprop routine.
  !
!bloss: not needed at present  use netcdf
  use grid, only: rundatadir, masterproc, dompi, reff_ice_holds_Dge
  use parkind, only : r8=>kind_rb ! Eight byte reals
  use parrrtm,      only : nbndlw ! Number of LW bands
  use parrrsw,      only : nbndsw ! Number of SW bands
  use rrlw_cld, only: absliq1, absice3
  use rrsw_cld, only: extliq1, ssaliq1, asyliq1, &
     extice3, ssaice3, asyice3, fdlice3

  private
  public :: p3_cloud_optics_init, compute_p3_cloud_optics

  logical, save :: initialized = .false.

  !bloss: save cloud property lookup tables locally with
  !   the two dimensions transposed.  This should make the
  !   memory retrieval work better, I think.

  ! liquid tables parameterized by effective radius, with length 46.  (16 bands)
  real(kind=r8) , dimension(16,58) :: absliq1TR
  real(kind=r8) , dimension(16:29,58) :: extliq1TR, ssaliq1TR, asyliq1TR

  ! ice tables parameterized by generalized effective size, with length 58.  (14 bands)
  real(kind=r8) , dimension(16,46) :: absice3TR
  real(kind=r8) , dimension(16:29,46):: extice3TR, ssaice3TR, asyice3TR, fdlice3TR

contains
  ! --------------------------------------------------------------------------------------  
  subroutine endrun(message)
    character(len=*), intent(in) :: message
    
    print *, message
    call task_abort()  
  end subroutine endrun
  ! --------------------------------------------------------------------------------------  
  subroutine p3_cloud_optics_init
    !
    ! Nothing to do here for now.
    !
    if(.not. initialized) then
      if(masterproc) write(*,*) 'Initializing P3 Cloud Optics'
      !-------------
      ! Liquid and ice cloud lookup tables generated by rrtmg_sw_ini, rrtmg_lw_ini
      ! Transpose them and store locally, so that bands are the inner dimension.
      !-------------
      absliq1TR(:,:) = TRANSPOSE(absliq1)
      extliq1TR(:,:) = TRANSPOSE(extliq1)
      ssaliq1TR(:,:) = TRANSPOSE(ssaliq1)
      asyliq1TR(:,:) = TRANSPOSE(asyliq1)

      absice3TR(:,:) = TRANSPOSE(absice3)
      extice3TR(:,:) = TRANSPOSE(extice3)
      ssaice3TR(:,:) = TRANSPOSE(ssaice3)
      asyice3TR(:,:) = TRANSPOSE(asyice3)
      fdlice3TR(:,:) = TRANSPOSE(fdlice3)

    end if
    initialized = .true.
  end subroutine p3_cloud_optics_init
  ! --------------------------------------------------------------------------------------  
  subroutine compute_p3_cloud_optics(nx, nz, ilat, layerMass, cloudFrac, &
       tauLW, tauSW, ssaSW, asmSW, forSW, tauSW_cldliq, tauSW_cldice, Reff_cldice) 
    !
    ! Provide total optical properties from all radiatively-active species: liquid, ice, and snow
    !   Liquid cloud lookup tables are drawn from RRTMG liqflag==1 and indexed by effective
    !   radius; ice and snow properties use the same table (RRTMG iceflag==3), indexed by
    !   generalized effective diameter
    !
    use micro_params, only: rho_cloud_ice, rho_snow
    use microphysics, only: &
         CloudLiquidMassMixingRatio, reffc, &
         IceMassMixingRatio_P3, ReffIce_P3, nCat_ice_P3

    integer,  intent(in ) :: nx, nz, ilat ! number of columns and levels
    real(r8), intent(in ) :: layerMass(nx,nz+1)
    real(r8), intent(inout)::cloudFrac(nx,nz+1)
    real(r8), intent(out) :: tauLW(nbndlw,nx,nz+1), &
                             tauSW(nbndsw,nx,nz+1), ssaSW(nbndsw,nx,nz+1), &
                             asmSW(nbndsw,nx,nz+1), forSW(nbndsw,nx,nz+1), &
                             tauSW_cldliq(nbndsw,nx,nz+1), &
                             tauSW_cldice(nbndsw,nx,nz+1), &
                             Reff_cldice(nx,nz+1)

    ! inputs to cloud_optics routines
    real(r8) :: lwp(nx,nz),  rel (nx,nz) ! liquid water path, effective radius from P3
    real(r8) :: iwp(nx,nz),  dgi (nx,nz)  ! cloud ice water path, ice generalized effective diameter
    real(r8) :: twp(nx,nz)
    real(r8) :: tauSW_Dge_cldice(nx,nz+1) ! accumulate both tauSW and tauSW*Dge across all ice categories.
    real(r8) :: tauSW_save(nbndsw,nx,nz+1) ! used to compute tauSW of each P3 ice category

    real(kind=r8) :: fac_Dge_over_reff 

    integer :: iloc(2), jloc

    ! ratio of Dge/reff, see eqn 10 in Fu (1996, JClim)
    fac_Dge_over_reff = 2./sqrt(3.)

    cloudFrac(:,:) = 0.

    !
    ! Individual routines report tau, tau*ssa, tau*ssa*asm, and tau*ssa*for; these are summed
    !   and normalized when all contributions have been added
    !
    ! Zero out optics arrays
    tauLW(:,:,:) = 0._r8
    tauSW(:,:,:) = 0._r8
    ssaSW(:,:,:) = 0._r8
    asmSW(:,:,:) = 0._r8
    forSW(:,:,:) = 0._r8

    tauSW_cldliq(:,:,:) = 0._r8
    tauSW_cldice(:,:,:) = 0._r8
    tauSW_Dge_cldice(:,:) = 0._r8

    ! first, liquid.
    lwp(1:nx,1:nz) = 1.e3*CloudLiquidMassMixingRatio(1:nx,ilat,1:nz)*LayerMass(1:nx,1:nz) ! scale from kg to g 
    rel(1:nx,1:nz) = MAX(2.51_r8, MIN(59.99_r8, reffc(1:nx,ilat,1:nz) ) )

    twp(1:nx,1:nz) = lwp(1:nx,1:nz)

    ! Liquid cloud optics routine puts zeros in non-cloudy cells
    call compute_liquid_cloud_optics(nx, nz, lwp, rel, tauLW, tauSW, ssaSW, asmSW, forSW)
    tauSW_cldliq(:,:,:) = tauSW(:,:,:)
    tauSW_save(:,:,:) = tauSW(:,:,:)

    do n = 1,nCat_ice_P3
      iwp(1:nx,1:nz) = 1.e3*IceMassMixingRatio_P3(1:nx,ilat,1:nz,n)*LayerMass(1:nx,1:nz) ! scale from kg to g 
      dgi(1:nx,1:nz) = ReffIce_P3(1:nx,ilat,1:nz,n)

      twp(1:nx,1:nz) = twp(1:nx,1:nz) + iwp(1:nx,1:nz) ! accumulate total water path

      if(.NOT.reff_ice_holds_Dge) then
        dgi(:,:) = dgi(:,:)*fac_Dge_over_reff
      end if

      ! Do not allow Dge below minimum in RRTMG lookup table
      dgi(1:nx,1:nz) = MAX(5.01_r8, dgi(1:nx,1:nz) ) 

      ! Ice clouds - routine adds to arrays
      call add_ice_cloud_optics(nx, nz, iwp, dgi, tauLW, tauSW, ssaSW, asmSW, forSW)

      ! This tauSW_cldice is the tau for a single ice category.
      tauSW_cldice(:,:,:) = tauSW(:,:,:) - tauSW_save(:,:,:) 
      tauSW_Dge_cldice(1:nx,1:nz) = tauSW_Dge_cldice(1:nx,1:nz) &
           + tauSW_cldice(9,1:nx,1:nz) * dgi(1:nx,1:nz) ! use band 9 tau to weight Dge.
      tauSW_save(:,:,:) = tauSW(:,:,:)
    end do
    ! Here, we compute the aggregate tauSW across all ice categories.
    tauSW_cldice(:,:,:) = tauSW(:,:,:) - tauSW_cldliq(:,:,:)

    ! Compute the optical-depth-weighted Dge using the band 9 optical depth
    Reff_cldice(:,:) = 25. ! fill value
    where(tauSW_cldice(9,:,:) > 0._r8)
      Reff_cldice(:,:) = (1./fac_Dge_over_reff) * tauSW_Dge_cldice(:,:) / tauSW_cldice(9,:,:)
    end where
    !
    ! Total cloud optical properties
    !
    where(ssaSW(:,:,:) > 0._r8) 
      asmSW(:,:,:) = asmSW(:,:,:)/ssaSW(:,:,:)
      forSW(:,:,:) = forSW(:,:,:)/ssaSW(:,:,:)
    end where             
    where(tauSW(:,:,:) > 0._r8) 
      ssaSW(:,:,:) = ssaSW(:,:,:)/tauSW(:,:,:)
    end where             

    !bloss: Re-define cloud fraction here.
    cloudFrac(1:nx,1:nz) = MERGE(1., 0., twp>0.)

!bloss    iloc = MAXLOC(SUM(tauSW(:,:,:),dim=1))
!bloss    write(*,999) MAXVAL(SUM(tauSW,dim=1)), rel(iloc(1),iloc(2)), lwp(iloc(1),iloc(2))
!bloss    iloc = MAXLOC(SUM(tauLW,dim=1))
!bloss    write(*,999) MAXVAL(SUM(tauLW,dim=1)), rel(iloc(1),iloc(2)), lwp(iloc(1),iloc(2))
!bloss    998 format('Max tauSW = ',F10.4,' rel at max tauSW= ',F10.4,' lwp at max tauSW= ',F10.4)
!bloss    999 format('Max tauLW = ',F10.4,' rel at max tauLW= ',F10.4,' lwp at max tauLW= ',F10.4)
  end subroutine compute_p3_cloud_optics
  ! --------------------------------------------------------------------------------------
  subroutine compute_liquid_cloud_optics(nx, nz, lwp, rel, tauLW, tauSW, taussaSW, taussagSW, taussafSW)
    integer,  intent(in) :: nx, nz ! number of columns and levels
    real(r8), intent(in) :: lwp(nx, nz),  rel(nx, nz) ! liquid water path, effective radius
    real(r8), intent(inout) :: tauLW(nbndlw,nx,nz+1), &
                             tauSW(nbndsw,nx,nz+1), taussaSW(nbndsw,nx,nz+1), &
                             taussagSW(nbndsw,nx,nz+1), taussafSW(nbndsw,nx,nz+1)
                             ! Provide tau, tau*ssa, tau*ssa*g, tau*ssa*f = tau*ssa*g*g to make
                             !   summing over liquid/ice/snow in calling routines more efficient.

    ! Interpolation variables
    integer  :: nUse, i, j, iloc(1)
    integer  :: iUse(nx*nz), jUse(nx*nz)
    integer  :: idx(nx*nz)
    real(r8) :: fint(nx*nz), onemfint(nx*nz), thisLWP
    real(r8) :: radliq(nx*nz)
    real(r8) :: ext(nbndsw), ssa(nbndsw), asm(nbndsw), liqabs(nbndlw)

    nUse = 0
    do j = 1, nz
      do i = 1, nx
        if(lwp(i,j) > 0.) then
          nUse = nUse + 1
          iUse(nUse) = i
          jUse(nUse) = j
        else
          tauLW    (1:nbndlw,i,j) = 0._r8
          tauSW    (1:nbndsw,i,j) = 0._r8
          taussaSW (1:nbndsw,i,j) = 0._r8
          taussagSW(1:nbndsw,i,j) = 0._r8
          taussafSW(1:nbndsw,i,j) = 0._r8
        end if 
      end do 
    end do 

    if(nUse.eq.0) return

    do i = 1, nUse
      ! work out indices and weights for liquid property lookup tables based
      !   on effective radius.
      ! Adapted from rrtmg_sw_cldprop.f90 -- same for longwave
      radliq(i)  = rel( iUse(i), jUse(i) )
      idx(i)  = MAX(1, MIN(57, int(radliq(i) - 1.5_r8) ) )
      fint(i) = MAX(0., MIN(1., radliq(i) - 1.5_r8 - float(idx(i)) ) )
      onemfint(i) = 1. - fint(i)
    end do

    ! Check to make sure we haven't exceede limits on lookup tables.
    if ( MINVAL( radliq(1:nUse) ).lt. 2.5_r8) then
      iloc = MINLOC(radliq(1:nUse))
      if(masterproc) write(*,*) 'Error in p3_cloud_optics.f90'
      if(masterproc) write(*,*) '**** Min liquid effective radius = ', radliq(iloc)
      if(masterproc) write(*,*) '**** Smaller than limit of 2.5 microns'
      if(masterproc) write(*,*) '**** LWP = ', lwp(iUse(iloc),jUse(iloc))
      call endrun('compute_cloud_optics: radliq out of bounds')
    elseif ( MAXVAL( radliq(1:nUse) ).gt. 60._r8) then
      iloc = MAXLOC(radliq(1:nUse))
      if(masterproc) write(*,*) 'Error in p3_cloud_optics.f90'
      if(masterproc) write(*,*) '**** Max liquid effective radius = ', MAXVAL(radliq(1:nUse))
      if(masterproc) write(*,*) '**** Larger than limit of 60 microns'
      if(masterproc) write(*,*) '**** LWP = ', lwp(iUse(iloc),jUse(iloc))
      call endrun('compute_cloud_optics: radliq out of bounds')
    end if

    do i = 1, nUse
      !
      ! Longwave cloud properties, interpolate from RRTMG table, liqflag==1
      !
      liqabs(:) = onemfint(i)*absliq1TR(:,idx(i)) + fint(i)*absliq1TR(:,idx(i)+1)
      !
      ! Shortwave cloud properties, interpolate from RRTMG table, liqflag==1
      !
      ext(:) = onemfint(i)*extliq1TR(:,idx(i)) + fint(i)*extliq1TR(:,idx(i)+1)
      ssa(:) = onemfint(i)*ssaliq1TR(:,idx(i)) + fint(i)*ssaliq1TR(:,idx(i)+1)
      asm(:) = onemfint(i)*asyliq1TR(:,idx(i)) + fint(i)*asyliq1TR(:,idx(i)+1)

      thisLWP = LWP( iUse(i), jUse(i))

      tauLW(:, iUse(i), jUse(i)) = thisLWP * liqabs(:)

      tauSW(:, iUse(i), jUse(i)) = thisLWP * ext(:)
      taussaSW (:,iUse(i),jUse(i)) = thisLWP * ext(:) * ssa(:)
      taussagSW(:,iUse(i),jUse(i)) = thisLWP * ext(:) * ssa(:) * asm(:)
      taussafSW(:,iUse(i),jUse(i)) = thisLWP * ext(:) * ssa(:) * asm(:) * asm(:) ! f = g**2
    end do
  end subroutine compute_liquid_cloud_optics
  ! --------------------------------------------------------------------------------------  
  subroutine add_ice_cloud_optics(nx, nz, wp, dg, tauLW, tauSW, tauSsaSW, tauSsaGSW, tauSsaFSW) 
    !
    ! Optical properties for ice or snow
    ! 
    integer,  intent(in) :: nx, nz ! number of columns and levels
    real(r8), intent(in) :: wp(nx, nz),  dg(nx, nz) ! cloud ice water path, ice  generalized effective diameter
    real(r8), intent(inout) :: tauLW(nbndlw,nx,nz+1), &
                               tauSW(nbndsw,nx,nz+1), tauSsaSW(nbndsw,nx,nz+1), &
                               tauSsaGSW(nbndsw,nx,nz+1), tauSsaFSW(nbndsw,nx,nz+1)
                             ! Provide tau, tau*ssa, tau*ssa*g, tau*ssa*f to make
                             !   summing over liquid/ice/snow in calling routines more efficient.

    integer  :: nuse, i, j
    integer  :: iUse(nx*nz), jUse(nx*nz)
    integer  :: idx(nx*nz)
    real(r8) :: fint(nx*nz), onemfint(nx*nz), thisIWP
    real(r8) :: extinction_scaling_factor(nx*nz), dge_ice(nx*nz)
    real(r8) :: ext(nbndsw), ssa(nbndsw), asm(nbndsw), fdelta(nbndsw), iceabs(nbndlw)
    real(r8) :: forwice(nbndsw)

    nUse = 0
    do j = 1, nz
      do i = 1, nx
        if(wp(i,j) > 0. .and. dg(i,j) > 0.) then 
          nUse = nUse + 1
          iUse(nUse) = i
          jUse(nUse) = j
        end if
      end do 
    end do 
    
    if (nUse.eq.0) return
    !
    !  Initialize extinction_scaling_factor to one.
    !   This is used to allow for ice sizes beyond the top end of the lookup table.
    extinction_scaling_factor(:) = 1._r8
    !
    ! Work out indexing into lookup table for iceflag==3 in rrtmg.
    !
    do i = 1, nUse
      !<<<<<<<<<<< THIS WOULD BE THE POINT TO WORRY ABOUT THE CONVERSION FROM 
      !     EFFECTIVE RADIUS TO GENERALIZED EFFECTIVE SIZE >>>>>>>>>>>>>>>
      dge_ice(i) = dg(iUse(i), jUse(i) ) 
      factor = ( dge_ice(i) - 2._r8)/3._r8
      idx(i) = MAX(1, MIN(45, FLOOR(factor) ) )
      fint(i) = MAX(0._r8, MIN(1._r8, factor - real(idx(i),KIND=r8) ) )
      onemfint(i) = 1._r8 - fint(i)

      ! We're going to use the lookup table for sizes greater than the top
      !   end value.  Based on advice from Qiang Fu, we rescale the extinction
      !   according to the ratio of the sizes but use the top-end values from
      !   table for the SSA, asymmetry parameter and forward-scattering-factor.
      !   Rescaling the extinction in this way should preserve the optical depth.
      extinction_scaling_factor(i) = MIN(1., 140._r8 / MAX( EPSILON(1.), dge_ice(i) ) )
    end do

    ! This would be the place to put a check for being out of bounds if we
    !   want to do that here.  Otherwise, we may rely on our extrapolation off
    !   the top edge of the table.
    if (MINVAL( dge_ice(1:nUse) ) .lt. 5.0_r8 ) then
        stop 'ICE GENERALIZED EFFECTIVE SIZE OUT OF BOUNDS'
    end if

    do i = 1,nUse
      !
      ! Longwave cloud properties, interpolate from RRTMG table, iceflag==3
      !
      iceabs(:) = onemfint(i)*absice3TR(:,idx(i)) + fint(i) * absice3TR(:,idx(i)+1)
      !
      ! Shortwave cloud properties, interpolate from RRTMG table, iceflag==3
      !
      ext(:) = onemfint(i)*extice3TR(:,idx(i)) + fint(i) * extice3TR(:,idx(i)+1)
      ssa(:) = onemfint(i)*ssaice3TR(:,idx(i)) + fint(i) * ssaice3TR(:,idx(i)+1)
      asm(:) = onemfint(i)*asyice3TR(:,idx(i)) + fint(i) * asyice3TR(:,idx(i)+1)
      fdelta(:) = onemfint(i)*fdlice3TR(:,idx(i)) + fint(i) * fdlice3TR(:,idx(i)+1)

      ! Check for issues
      if (MINVAL(fdelta(:)) .lt. 0.0_r8) stop 'FDELTA LESS THAN 0.0'
      if (MAXVAL(fdelta(:)) .gt. 1.0_r8) stop 'FDELTA GT THAN 1.0'

      ! rescale FSF according to Fu 1996 p. 2067, follow rrtmg_sw_cldprop.f90
      forwice(:) = fdelta(:) + 0.5_r8 / ssa(:)
      forwice(:) = MIN( forwice(:), asm(:) ) ! FSF <= ASYMMETRY PARAMETER

      ! Check to ensure all calculated quantities are within physical limits.
      if (MINVAL(ext(:)) .lt. 0.0_r8) stop 'ICE EXTINCTION LESS THAN 0.0'
      if (MAXVAL(ssa(:)) .gt. 1.0_r8) stop 'ICE SSA GRTR THAN 1.0'
      if (MINVAL(ssa(:)) .lt. 0.0_r8) stop 'ICE SSA LESS THAN 0.0'
      if (MAXVAL(asm(:)) .gt. 1.0_r8) stop 'ICE ASYM GRTR THAN 1.0'
      if (MINVAL(asm(:)) .lt. 0.0_r8) stop 'ICE ASYM LESS THAN 0.0'

      ! scale LW absorption and SW extinction by D_max / D_ice
      !    where D_max is the maximum value of D permitted in the lookup table.
      !    This should preserve the optical depth of the ice, even if D_ice>D_max.
      iceabs(:) = iceabs(:) * extinction_scaling_factor(i)
      ext(:)    = ext(:)    * extinction_scaling_factor(i)

      thisIWP = wp(iUse(i),jUse(i))

      ! accumulate LW cloud properties, adding to previous values
      tauLW(:, iUse(i), jUse(i)) = tauLW(:, iUse(i), jUse(i)) + thisIWP * iceabs(:)

      ! accumulate SW optical properties, adding to previous values
      tauSW(:, iUse(i), jUse(i)) = tauSW(:, iUse(i), jUse(i)) + thisIWP * ext(:)
      taussaSW (:,iUse(i),jUse(i)) = taussaSW (:,iUse(i),jUse(i)) + thisIWP * ext(:) * ssa(:)
      taussagSW(:,iUse(i),jUse(i)) = taussagSW(:,iUse(i),jUse(i)) + thisIWP * ext(:) * ssa(:) * asm(:)
      taussafSW(:,iUse(i),jUse(i)) = taussafSW(:,iUse(i),jUse(i)) + thisIWP * ext(:) * ssa(:) * forwice(:)
    end do

  end subroutine add_ice_cloud_optics

  ! --------------------------------------------------------------------------------------  
end module p3_cloud_optics 
